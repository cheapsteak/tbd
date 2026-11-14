#!/usr/bin/env python3
"""Turn a `log show` capture of TBD's terminal latency lines into the table.

WHAT THE NUMBERS ARE
--------------------
Two instruments, measured inside TBDApp, on both terminal transports and both
terminal engines, by one mechanism
(`Sources/TBDApp/Terminal/TerminalLatencyTap.swift`):

  echo  -- a token written through a panel's REAL keystroke path, stamped
           again when its first copy comes back at the app's feed seam. The
           loop spans the pty, the line discipline, and on tmux the server, so
           this is the transport's number and it is the only one here that
           compares the two transports.

  draw  -- how long the OLDEST chunk in a frame sat parsed-but-undrawn before
           that panel's view started drawing. Identical in mechanism on both
           transports, because both feed through the same line of code. It
           cannot see anything BEFORE the app's read -- which is precisely
           where tmux sits -- so it never compares transports by itself.

There are two modes. TRANSPORT MODE, the default, has one arm per transport,
`tmux` and `holder`, and an arm holds every line its transport carries. ENGINE
MODE (`--swiftterm-terminal`, `--ghostty-terminal`) has one arm per terminal
engine, `swiftterm` and `libghostty`; see ENGINE MODE below.

THE DRAW LINE IS THE CHECK ON THE ECHO LINE, AND THAT IS WHY BOTH PRINT
----------------------------------------------------------------------
If the two arms' draw waits agree and their echoes differ, the difference is
upstream of the app: the transport. If the draw waits DISAGREE, the arms are
not being measured the same way and the echo comparison is suspect. Both are
printed so that check is always in front of you rather than optional. In
engine mode the two lines swap roles.

ENGINE MODE
-----------
Both arms are holder terminals, one on SwiftTerm and one on libghostty
(`docs/specs/2026-11-07-libghostty-terminal-engine-design.md`). Every line
carries `transport=holder`, so a line belongs to an arm by its terminal id
alone, and lines from any other terminal are left out of every figure.

  echo  -- the same loop on both arms. The token enters the outbound path
           after the engine's own key handling, and its copy is stamped at the
           feed seam BEFORE the engine parses it, so neither engine's work is
           inside the number. In this mode the echo is the CHECK: matched arms
           echo alike, and a gap means unmatched arms or an engine that keeps
           the app's main or reader thread busy.

  draw  -- the engines' own number: from a chunk reaching the feed seam, its
           parse included, to the engine starting a draw. SwiftTerm stamps
           that start in `viewWillDraw`, libghostty when it builds a frame.

Because the draw wait is the measure that tells the engines apart, its
on-screen samples are split into load bands too, never pooled. A draw line
carries no sequence number, so each one is placed by time: by the latest
request of its arm issued before the draw's oldest chunk reached the feed
seam (the line's log time less that chunk's wait). A draw always follows its
request, so the request after it cannot be the one. A draw with no log time,
one fed before the arm's first request or more than a second after its last,
or one whose request has no load recorded joins neither band and is counted
on its arm's `draw bands` line. The request times come from the driver, in
the load map's `times` entry.

The latency lines do not name an engine, and only the app knows which engine
a terminal is on. This script takes the two ids as given. The driver,
`terminal-latency-probe.py`, confirms each id's engine from the app's own
engine log lines and its defaults, before and after the run.

WHAT IT CANNOT SHOW
-------------------
- Pixels. The draw endpoint is the START of a draw; the commit probe covers
  the app-side commit and nothing covers the compositor.
- An agent's response. `cat` echo is the line discipline (or tmux) answering,
  not a TUI repainting. It says nothing about how fast Claude Code redraws.
- A fair comparison without a fair run. On this machine a load swing from 7 to
  139 once faked a threefold effect that vanished under matched load, so
  samples are never pooled across load bands: pass `--load-map` and
  `--idle-max` and the echo figures split into idle and load. A sample whose
  load was never recorded joins NEITHER band and is counted on its arm's
  `no load recorded` line.
- Which panel a number came from, unless you say. A capture holds every panel
  that was open, so `--terminals` restricts the echo and draw figures to the
  ids that were probed; without it, an arm whose lines came from more than one
  terminal is broken out per terminal so the contamination is visible. Engine
  mode always restricts to its two ids.
- A draw wait under SwiftTerm's Metal renderer (`viewWillDraw` is not on that
  frame path, so it emits no draw lines at all). libghostty always draws with
  Metal, and does emit draw lines.

THE VERDICT LINES
-----------------
The pty-holder transport spec's Rollout section makes graduation depend on a
paired measurement: p90 keystroke echo at load no more than 2x p90 at idle,
and no more than 5 ms. With `--load-map` and `--idle-max` this script prints
both comparisons per arm. It supplies the numbers; the verdict over the
spec's four conditions (workload, sample size, absolute bound, flatness bound)
is a human judgement.

In engine mode those lines carry the engine's name, and an ENGINES section
sets libghostty's p90 against SwiftTerm's, band against band: echo idle, echo
load, draw idle, draw load. The libghostty engine spec's A/B section makes
graduation need a clear win: a p90 at least 20% lower on one measure (0.80x or
less), repeated in two A/B/B/A runs, with no regression beyond noise on the
others. Each line says whether this run meets the 20% bar. The ratio prints to
three decimals and the verdict is read off that printed ratio, with the
percentage rounded down, so a line never shows a ratio on one side of the bar
and a verdict on the other. Every line prints both arms' sample counts. A
measure that could not be banded prints its pooled figures and no verdict, and
so does a band with fewer than ten samples on either arm, where the p90 is just
the largest sample. The second run, the no-regression condition and whether
the sample size is enough are a human judgement.

USAGE
-----
    defaults write com.github.cheapsteak.tbd enableTerminalLatencyDiagnostic -bool true
    # (an unbundled `swift run` build reads the TBDApp domain instead)
    # relaunch TBDApp (scripts/restart.sh), then drive a run:
    scripts/diag/terminal-latency-probe.py \\
        --worktree <name> \\
        --tmux-terminal <uuid> --holder-terminal <uuid>

    # or an engine A/B:
    scripts/diag/terminal-latency-probe.py \\
        --worktree <name> \\
        --swiftterm-terminal <uuid> --ghostty-terminal <uuid>

    # or read a capture by hand:
    log show --last 10m --info \\
      --predicate 'subsystem == "com.tbd.app" AND category == "terminallatency"' \\
      | scripts/diag/terminal-latency-report.py

    # an engine-mode capture by hand, banded with the map the driver kept
    # (--keep-load-map), which carries the request times the draws need:
    ... | scripts/diag/terminal-latency-report.py \\
        --swiftterm-terminal <uuid> --ghostty-terminal <uuid> \\
        --load-map <kept map> --idle-max 8

    scripts/diag/terminal-latency-report.py --self-test
"""

from __future__ import annotations

import argparse
import bisect
import datetime
import json
import math
import re
import sys
from dataclasses import dataclass, field

# One emitted line, anchored at the verb so a `log show` prefix (timestamp,
# process, subsystem) is skipped without having to model it. The key=value run
# goes to end-of-line because that is how the app emits it -- every line ends
# with its last field.
LINE_RE = re.compile(r"\b(draw|echo|echolost|echorefused) ((?:[a-z]+=\S+)(?: [a-z]+=\S+)*)\s*$")

# The time `log show` puts at the start of a line: with a UTC offset in its
# default style, without one in `--style compact`. Read for draw lines only,
# which engine mode places in load bands by time.
LOG_TIME_RE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{1,6})([+-]\d{4})?\s")

# How long after an arm's last request a draw may be fed and still be placed
# by it: the driver waits a second for the last echo before it reads the log.
DRAW_SETTLE_SECONDS = 1.0

# Why an on-screen draw joined neither band, in the order they print.
DRAW_UNPLACED_REASONS = ("outside the run", "no load recorded", "no log time", "no request times")

TRANSPORTS = ("tmux", "holder")

# Engine mode's arm labels, in A/B order. Both arms are on one transport.
ENGINES = ("swiftterm", "libghostty")
ENGINE_TRANSPORT = "holder"

# The libghostty engine spec's bar for a clear win: libghostty's p90 at most
# 0.80 of SwiftTerm's, which is 20% lower.
ENGINE_WIN_RATIO = 0.80

# The fewest samples an arm needs on a measure before an ENGINES line gives a
# verdict. Below ten, the nearest-rank p90 is the arm's largest sample.
ENGINE_MIN_SAMPLES = 10

# The load map's entry for when each request was issued, beside the arms'
# entries. The driver writes it in engine mode only.
REQUEST_TIMES_KEY = "times"


@dataclass(frozen=True, slots=True)
class Arm:
    """One side of the comparison, and which lines are its own.

    In transport mode there is one arm per transport, and it holds every line
    on that transport (`--terminals` has already removed foreign panels). In
    engine mode there is one arm per engine, and it holds the lines of exactly
    one terminal: both terminals are on the holder transport, so the id is the
    only thing that tells their lines apart.
    """

    label: str
    transport: str
    # As given, for display. Compared case-insensitively.
    terminal: str | None = None

    def owns(self, record) -> bool:
        if record.transport != self.transport:
            return False
        return self.terminal is None or record.terminal.lower() == self.terminal.lower()


def transport_arms() -> list[Arm]:
    return [Arm(label=transport, transport=transport) for transport in TRANSPORTS]


def engine_arms(swiftterm_terminal: str, ghostty_terminal: str) -> list[Arm]:
    swiftterm, libghostty = ENGINES
    return [
        Arm(label=swiftterm, transport=ENGINE_TRANSPORT, terminal=swiftterm_terminal),
        Arm(label=libghostty, transport=ENGINE_TRANSPORT, terminal=ghostty_terminal),
    ]


@dataclass(slots=True)
class Echo:
    transport: str
    terminal: str
    seq: int
    ms: float


@dataclass(slots=True)
class Draw:
    transport: str
    terminal: str
    chunks: int
    oldest_ms: float
    newest_ms: float
    parse_max_ms: float
    dropped: int
    visible: bool
    # When the line was logged, in epoch seconds, or None when the capture
    # carries no time.
    at: float | None = None


@dataclass(slots=True)
class Lost:
    transport: str
    terminal: str
    seq: int


@dataclass(slots=True)
class Refusal:
    terminal: str
    reason: str


@dataclass(slots=True)
class Capture:
    echoes: list[Echo] = field(default_factory=list)
    draws: list[Draw] = field(default_factory=list)
    # Kept as records rather than tallies, because every figure here can be
    # restricted to the terminals that were probed and a tally cannot be.
    lost: list[Lost] = field(default_factory=list)
    refusals: list[Refusal] = field(default_factory=list)
    # Lines that matched the verb but not the fields they must carry. Counted
    # rather than dropped: a format drift must be visible, not silent.
    malformed: int = 0
    # Draw lines whose reported wait was negative. A wait cannot be negative,
    # so such a line is REFUSED rather than floored into a distribution: a
    # fabricated 0.000 would pull p50 down and look like a measurement. The
    # app floors these at the source; this is the defence against a capture
    # taken from a build that does not.
    negative_waits: int = 0

    def lost_count(self, arm: Arm, wanted: set[str] | None = None) -> int:
        """Lost tokens on one arm, over the terminals asked for."""
        return sum(
            1
            for record in self.lost
            if (wanted is None or record.terminal.lower() in wanted) and arm.owns(record)
        )

    def refusal_counts(self, wanted: set[str] | None = None) -> dict[str, int]:
        """Refusals per reason, over the terminals asked for.

        A refusal the app could not attribute is emitted as `terminal=-` and so
        belongs to no id: under `--terminals` it drops out with every other
        foreign line. The driver prints this tally UNFILTERED when it refuses a
        run, which is where an undecodable request has to be visible.
        """
        out: dict[str, int] = {}
        for record in self.refusals:
            if wanted is not None and record.terminal.lower() not in wanted:
                continue
            out[record.reason] = out.get(record.reason, 0) + 1
        return out


def parse_fields(blob: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for token in blob.split():
        key, _, value = token.partition("=")
        if value:
            out[key] = value
    return out


def parse_log_time(line: str) -> float | None:
    """The epoch time at the start of a `log show` line, or None. A time with
    no offset is local, as `--style compact` prints it."""
    match = LOG_TIME_RE.match(line)
    if not match:
        return None
    stamp, offset = match.group(1), match.group(2)
    try:
        if offset:
            return datetime.datetime.strptime(stamp + offset, "%Y-%m-%d %H:%M:%S.%f%z").timestamp()
        return datetime.datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S.%f").timestamp()
    except ValueError:
        return None


def parse(stream) -> Capture:
    capture = Capture()
    for line in stream:
        match = LINE_RE.search(line.rstrip("\n"))
        if not match:
            continue
        verb, blob = match.group(1), match.group(2)
        fields = parse_fields(blob)
        try:
            if verb == "echo":
                capture.echoes.append(
                    Echo(
                        transport=fields["transport"],
                        terminal=fields["terminal"],
                        seq=int(fields["seq"]),
                        ms=float(fields["ms"]),
                    )
                )
            elif verb == "draw":
                draw = Draw(
                    transport=fields["transport"],
                    terminal=fields["terminal"],
                    chunks=int(fields["chunks"]),
                    oldest_ms=float(fields["oldestms"]),
                    newest_ms=float(fields["newestms"]),
                    parse_max_ms=float(fields["parsemaxms"]),
                    dropped=int(fields["dropped"]),
                    visible=fields["vis"] == "1",
                    at=parse_log_time(line),
                )
                if draw.oldest_ms < 0 or draw.newest_ms < 0:
                    capture.negative_waits += 1
                else:
                    capture.draws.append(draw)
            elif verb == "echolost":
                capture.lost.append(
                    Lost(
                        transport=fields["transport"],
                        terminal=fields["terminal"],
                        seq=int(fields["seq"]),
                    )
                )
            elif verb == "echorefused":
                capture.refusals.append(
                    Refusal(terminal=fields["terminal"], reason=fields["reason"])
                )
        except (KeyError, ValueError):
            capture.malformed += 1
    return capture


def percentile(values: list[float], fraction: float) -> float:
    """Nearest-rank percentile, rank = ceil(p*n), clamped. `values` sorted.

    `ceil`, not `round(p*n + 0.5)`: Python rounds half to even, so that form
    overshoots -- at n=100 it puts p99 on rank 100, reporting the maximum.
    Matches `commit-latency-report.py`.
    """
    if not values:
        return float("nan")
    rank = max(1, min(len(values), math.ceil(fraction * len(values))))
    return values[rank - 1]


def distribution(values: list[float]) -> dict[str, float]:
    ordered = sorted(values)
    return {
        "n": len(ordered),
        "p50": percentile(ordered, 0.50),
        "p90": percentile(ordered, 0.90),
        "p99": percentile(ordered, 0.99),
        "max": ordered[-1] if ordered else float("nan"),
    }


def format_distribution(label: str, stats: dict[str, float]) -> str:
    if not stats["n"]:
        return f"  {label:<22} (no samples)"
    return (
        f"  {label:<22} n={int(stats['n']):<6}"
        f" p50={stats['p50']:8.3f}"
        f" p90={stats['p90']:8.3f}"
        f" p99={stats['p99']:8.3f}"
        f" max={stats['max']:8.3f}"
    )


def load_for(load_map: dict | None, arm: str, seq: int) -> float | None:
    """The 1-minute load average recorded alongside one sample.

    Shape, as the driver writes it: {"<arm>": {"<seq>": <load>}}, where an arm
    is a transport, or in engine mode an engine. JSON object keys are strings,
    so the sequence number is looked up as one.
    """
    if not load_map:
        return None
    readings = load_map.get(arm)
    if not readings:
        return None
    value = readings.get(str(seq))
    return None if value is None else float(value)


def short_terminal(terminal: str) -> str:
    """A terminal id short enough to label a column with, still recognisable.

    Ids are opaque to this script; uppercase UUIDs are only what the app
    happens to emit today.
    """
    return terminal if len(terminal) <= 14 else f"{terminal[:8]}..{terminal[-4:]}"


def by_terminal(records: list, transport: str) -> dict[str, list]:
    """One transport's records, grouped by the terminal that produced them."""
    grouped: dict[str, list] = {}
    for record in records:
        if record.transport != transport:
            continue
        grouped.setdefault(record.terminal, []).append(record)
    return grouped


def split_bands(
    samples: list[Echo], arm: str, idle_max: float, load_map: dict
) -> tuple[list[float], list[float], int]:
    """One arm's echoes split into the idle band and the load band, and how
    many had no load recorded.

    A sample whose load was never recorded belongs to NEITHER band. It used
    to be counted as idle, which quietly put an under-load sample in the
    denominator of the flatness ratio.
    """
    idle: list[float] = []
    under_load: list[float] = []
    unknown = 0
    for sample in samples:
        load = load_for(load_map, arm, sample.seq)
        if load is None:
            unknown += 1
        elif load <= idle_max:
            idle.append(sample.ms)
        else:
            under_load.append(sample.ms)
    return idle, under_load, unknown


def split_draw_bands(
    draws: list[Draw],
    arm: str,
    idle_max: float,
    load_map: dict,
    request_times: dict | None,
) -> tuple[list[float], list[float], dict[str, int]]:
    """One arm's draw waits split into the idle band and the load band, and
    how many joined neither, by reason.

    A draw line carries no sequence number, so a draw is placed by the
    latest request of its arm issued before its oldest chunk reached the feed
    seam: its log time less that chunk's wait. A draw always follows its
    request, so the request after it cannot be the one. `request_times` is
    {"<arm>": {"<seq>": <epoch seconds>}}, as the driver records it.
    """
    arm_times = (request_times or {}).get(arm) or {}
    issued = sorted((float(when), int(seq)) for seq, when in arm_times.items())
    issued_at = [when for when, _ in issued]
    idle: list[float] = []
    under_load: list[float] = []
    unplaced: dict[str, int] = {}
    for draw in draws:
        if draw.at is None:
            reason = "no log time"
        elif not issued:
            reason = "no request times"
        else:
            fed = draw.at - draw.oldest_ms / 1000.0
            index = bisect.bisect_right(issued_at, fed) - 1
            if index < 0 or fed > issued_at[-1] + DRAW_SETTLE_SECONDS:
                reason = "outside the run"
            else:
                load = load_for(load_map, arm, issued[index][1])
                if load is None:
                    reason = "no load recorded"
                else:
                    (idle if load <= idle_max else under_load).append(draw.oldest_ms)
                    continue
        unplaced[reason] = unplaced.get(reason, 0) + 1
    return idle, under_load, unplaced


def engine_comparison_line(
    name: str, ghostty: list[float], swiftterm: list[float], unbanded: str | None = None
) -> str:
    """libghostty's p90 against SwiftTerm's on one measure, and whether it is
    the clear win the libghostty engine spec's graduation asks for.

    `unbanded` says why the samples are pooled across load bands. Such a line
    prints its figures and no verdict: a pooled p90 can hide a regression in
    one band behind a win in the other. So does a line with fewer than
    `ENGINE_MIN_SAMPLES` samples on either arm.
    """
    if not ghostty or not swiftterm:
        return f"  {name:<22} libghostty n={len(ghostty)} / swiftterm n={len(swiftterm)} (no samples on one arm)"
    ghostty_p90 = percentile(sorted(ghostty), 0.90)
    swiftterm_p90 = percentile(sorted(swiftterm), 0.90)
    figures = (
        f"libghostty {ghostty_p90:.3f} (n={len(ghostty)}) / swiftterm {swiftterm_p90:.3f} (n={len(swiftterm)})"
    )
    if swiftterm_p90 <= 0:
        return f"  {name:<22} {figures} (no ratio: swiftterm's p90 is 0)"
    # The verdict is read off the ratio as printed, in thousandths, and the
    # percentage is rounded down: a line can then never print a ratio on one
    # side of the bar beside a verdict from the other.
    shown = f"{ghostty_p90 / swiftterm_p90:.3f}"
    if unbanded is not None:
        return f"  {name:<22} {figures} = {shown}x (not banded: {unbanded}; no verdict)"
    if min(len(ghostty), len(swiftterm)) < ENGINE_MIN_SAMPLES:
        return f"  {name:<22} {figures} = {shown}x (too few samples; no verdict)"
    thousandths = int(shown.replace(".", ""))
    bar = round(ENGINE_WIN_RATIO * 1000)
    if thousandths == 1000:
        return f"  {name:<22} {figures} = {shown}x (no difference)"
    percent = abs(1000 - thousandths) // 10
    change = f"libghostty {percent}%" if percent else "libghostty under 1%"
    if thousandths <= bar:
        verdict = f"{change} lower: MEETS the 20% bar"
    elif thousandths < 1000:
        verdict = f"{change} lower: SHORT of the 20% bar"
    else:
        verdict = f"{change} higher"
    return f"  {name:<22} {figures} = {shown}x ({verdict})"


def report(
    capture: Capture,
    out=sys.stdout,
    idle_max: float | None = None,
    load_map: dict | None = None,
    terminals: set[str] | None = None,
    note: str | None = None,
    arms: list[Arm] | None = None,
    request_times: dict | None = None,
) -> None:
    """Print the run's figures.

    `note` is a banner the CALLER knows and this function cannot: whether the
    run that produced this capture finished. It is printed with the header,
    above every figure, so a reader cannot reach the table without having read
    it.

    `arms` selects engine mode (`engine_arms`). Engine arms name their own
    terminals, so `terminals` must be None with them. Omitted, the arms are
    the two transports.

    `request_times`, {"<arm>": {"<seq>": <epoch seconds>}}, is when the driver
    issued each request. Engine mode needs it, beside the load map, to band
    the draw waits; transport mode reads none of it.
    """
    engine_mode = arms is not None
    if engine_mode:
        if terminals is not None:
            raise ValueError("engine arms name their own terminals; pass no `terminals`")
        terminals = {arm.terminal for arm in arms if arm.terminal is not None}
    else:
        arms = transport_arms()
    banded = idle_max is not None and load_map is not None
    # Why engine mode's draw waits cannot be banded, or None when they can.
    draw_unbanded: str | None
    if not banded:
        draw_unbanded = "no load map"
    elif not request_times:
        draw_unbanded = "no request times"
    else:
        draw_unbanded = None

    # A capture is whatever the app logged in the window, which includes every
    # OTHER panel that happened to be open. Restricting to the probed ids is
    # the only way a pooled figure is known to be one terminal's.
    wanted = {t.lower() for t in terminals} if terminals is not None else None
    if wanted is not None:
        echoes = [e for e in capture.echoes if e.terminal.lower() in wanted]
        draws = [d for d in capture.draws if d.terminal.lower() in wanted]
    else:
        echoes = capture.echoes
        draws = capture.draws

    if engine_mode:
        print("terminal engine latency, milliseconds", file=out)
        print(
            "echo = keystroke round trip through the real input path"
            " (the same loop on both engines: the check)",
            file=out,
        )
        print(
            "draw = oldest chunk's wait before its panel drew (compares engines)",
            file=out,
        )
    else:
        print("terminal transport latency, milliseconds", file=out)
        print(
            "echo = keystroke round trip through the real input path (compares transports)",
            file=out,
        )
        print(
            "draw = oldest chunk's wait before its panel drew (does NOT compare transports)",
            file=out,
        )
    if note:
        print(f"\n{note}", file=out)
    if engine_mode:
        # As given, like the `only terminals` line: a reader is checking these
        # against the ids they passed, and against the arm each one went to.
        print(
            "\narms: "
            + ", ".join(f"{arm.label} = {short_terminal(arm.terminal or '-')}" for arm in arms),
            file=out,
        )
    elif terminals is not None:
        # Echoed as given, not as compared: the lowercase form is an
        # implementation detail of the match, and a reader is checking these
        # against the ids they passed.
        print(
            "\nonly terminals: " + ", ".join(sorted(short_terminal(t) for t in terminals)),
            file=out,
        )
    if capture.malformed:
        print(
            f"\n!! {capture.malformed} line(s) carried the verb but not its fields --"
            " the emitted format and this parser have drifted apart.",
            file=out,
        )
    if capture.negative_waits:
        print(
            f"\n!! {capture.negative_waits} draw line(s) reported a negative wait and were"
            " DISCARDED -- a draw was stamped before a chunk it then reported."
            " Expect none from a current build; a capture full of them is not a"
            " measurement of the draw path.",
            file=out,
        )

    # Restricted the same way, so an arm that contributed nothing to this run
    # is absent rather than present with `(no samples)` beside another panel's
    # lost token.
    refusal_counts = capture.refusal_counts(wanted)

    # Kept per arm for the ENGINES comparison, which sets one arm's figures
    # against the other's after both have printed.
    echo_all: dict[str, list[float]] = {}
    echo_bands: dict[str, tuple[list[float], list[float]]] = {}
    draws_on_screen: dict[str, list[float]] = {}
    draw_bands: dict[str, tuple[list[float], list[float]]] = {}

    print("\nECHO", file=out)
    for arm in arms:
        label = arm.label
        samples = [e for e in echoes if arm.owns(e)]
        lost = capture.lost_count(arm, wanted)
        if not samples and not lost:
            continue
        echo_all[label] = [e.ms for e in samples]
        print(format_distribution(f"{label} all", distribution(echo_all[label])), file=out)
        if lost:
            print(f"  {label + ' lost':<22} {lost} token(s) never came back", file=out)
        # Unfiltered, an arm's figures may pool two panels. Break them out so
        # that is visible rather than assumed away.
        groups = by_terminal(samples, arm.transport)
        if wanted is None and len(groups) > 1:
            for terminal, group in sorted(groups.items()):
                print(
                    format_distribution(
                        f"{label} {short_terminal(terminal)}",
                        distribution([e.ms for e in group]),
                    ),
                    file=out,
                )
        # Both or neither — `main` refuses the half-given form — and naming
        # each one here is also what lets a type checker see that the
        # comparison below is against a number.
        if idle_max is None or load_map is None:
            continue
        idle, under_load, unknown = split_bands(samples, label, idle_max, load_map)
        echo_bands[label] = (idle, under_load)
        print(format_distribution(f"{label} idle", distribution(idle)), file=out)
        print(format_distribution(f"{label} load", distribution(under_load)), file=out)
        print(
            f"  {label + ' unbanded':<22} no load recorded: {unknown}"
            f" (excluded from both bands)",
            file=out,
        )
        # The two verdicts need different things, so they are printed under
        # different conditions. Flatness is a RATIO and needs both bands; the
        # absolute bound is a statement about the load band alone, and a
        # capture taken entirely under load -- an arm that never saw an idle
        # minute -- can still answer it. Gating both on `idle and under_load`
        # silently withheld the one verdict such a capture supports.
        load_p90 = percentile(sorted(under_load), 0.90) if under_load else None
        if idle and load_p90 is not None:
            idle_p90 = percentile(sorted(idle), 0.90)
            ratio = load_p90 / idle_p90 if idle_p90 else float("inf")
            flat = "WITHIN" if ratio <= 2.0 else "OVER"
            print(
                f"  {label + ' flatness':<22} p90 load / p90 idle = {ratio:.2f}x"
                f" ({flat} the 2x bound)",
                file=out,
            )
        if load_p90 is not None:
            bound = "WITHIN" if load_p90 <= 5.0 else "OVER"
            print(
                f"  {label + ' absolute':<22} p90 under load = {load_p90:.3f} ms"
                f" ({bound} the 5 ms bound)",
                file=out,
            )

    if refusal_counts:
        print("\nREFUSED", file=out)
        for reason in sorted(refusal_counts):
            print(f"  {reason:<22} {refusal_counts[reason]}", file=out)

    print("\nDRAW (oldest chunk's wait)", file=out)
    for arm in arms:
        label = arm.label
        own = [d for d in draws if arm.owns(d)]
        if not own:
            continue
        visible = [d for d in own if d.visible]
        draws_on_screen[label] = [d.oldest_ms for d in visible]
        # On-screen first, because a panel the user never sees is work nobody
        # waited for; the all-draws line is kept beside it so an arm that drew
        # mostly off-screen cannot look like an arm that barely drew.
        print(
            format_distribution(f"{label} on screen", distribution(draws_on_screen[label])),
            file=out,
        )
        print(
            format_distribution(
                f"{label} all draws", distribution([d.oldest_ms for d in own])
            ),
            file=out,
        )
        # Engine mode compares on-screen draws band against band, so they are
        # split as the echoes are. `draw_unbanded` is None only when `idle_max`
        # and `load_map` are both given; naming them again lets a type checker
        # see it.
        if engine_mode and draw_unbanded is None and idle_max is not None and load_map is not None:
            idle, under_load, unplaced = split_draw_bands(
                visible, label, idle_max, load_map, request_times
            )
            draw_bands[label] = (idle, under_load)
            print(format_distribution(f"{label} draw idle", distribution(idle)), file=out)
            print(format_distribution(f"{label} draw load", distribution(under_load)), file=out)
            details = ", ".join(
                f"{unplaced[reason]} {reason}" for reason in DRAW_UNPLACED_REASONS if unplaced.get(reason)
            )
            print(
                f"  {label + ' draw bands':<22} in neither band: {sum(unplaced.values())}"
                + (f" ({details})" if details else ""),
                file=out,
            )
        groups = by_terminal(own, arm.transport)
        if wanted is None and len(groups) > 1:
            # The draw line is the CHECK on the echo comparison, so an arm
            # whose draws came from two panels has to say so: one of them may
            # be a panel nobody probed, drawing on a different schedule.
            for terminal, group in sorted(groups.items()):
                print(
                    format_distribution(
                        f"{label} {short_terminal(terminal)}",
                        distribution([d.oldest_ms for d in group]),
                    ),
                    file=out,
                )
        parse_max = max((d.parse_max_ms for d in own), default=0.0)
        dropped = sum(d.dropped for d in own)
        chunks = sum(d.chunks for d in own)
        print(
            f"  {label + ' chunks':<22} {chunks} fed, {dropped} dropped past the ring,"
            f" worst parse {parse_max:.3f} ms",
            file=out,
        )

    if not engine_mode:
        return

    # Matched band against matched band. A measure that could not be banded
    # prints its pooled figures with no verdict. SwiftTerm under its Metal
    # renderer emits no draw lines, so the draw comparison then says it has
    # nothing to compare.
    swiftterm, libghostty = ENGINES
    print(
        "\nENGINES (p90, libghostty / swiftterm; a clear win is 0.80x or less,"
        f" repeated in two runs; a verdict needs {ENGINE_MIN_SAMPLES} samples an arm)",
        file=out,
    )
    if banded:
        for index, band in enumerate(("idle", "load")):
            print(
                engine_comparison_line(
                    f"echo {band}",
                    echo_bands.get(libghostty, ([], []))[index],
                    echo_bands.get(swiftterm, ([], []))[index],
                ),
                file=out,
            )
    else:
        print(
            engine_comparison_line(
                "echo all",
                echo_all.get(libghostty, []),
                echo_all.get(swiftterm, []),
                unbanded="no load map",
            ),
            file=out,
        )
    if draw_unbanded is None:
        for index, band in enumerate(("idle", "load")):
            print(
                engine_comparison_line(
                    f"draw {band}",
                    draw_bands.get(libghostty, ([], []))[index],
                    draw_bands.get(swiftterm, ([], []))[index],
                ),
                file=out,
            )
    else:
        print(
            engine_comparison_line(
                "draw on screen",
                draws_on_screen.get(libghostty, []),
                draws_on_screen.get(swiftterm, []),
                unbanded=draw_unbanded,
            ),
            file=out,
        )


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

SELF_TEST_LINES = """\
2026-09-22 10:00:00.100000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] echo transport=tmux terminal=AAAA seq=1 ms=1.000
2026-09-22 10:00:00.200000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] echo transport=tmux terminal=AAAA seq=2 ms=2.000
2026-09-22 10:00:00.300000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] echo transport=tmux terminal=AAAA seq=3 ms=9.000
2026-09-22 10:00:00.400000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] echo transport=tmux terminal=AAAA seq=4 ms=11.000
2026-09-22 10:00:00.500000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] echo transport=holder terminal=BBBB seq=1 ms=0.500
2026-09-22 10:00:00.600000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] echo transport=holder terminal=BBBB seq=2 ms=0.700
2026-09-22 10:00:00.700000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] echo transport=holder terminal=BBBB seq=3 ms=0.900
2026-09-22 10:00:00.800000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] echo transport=holder terminal=BBBB seq=4 ms=1.100
2026-09-22 10:00:00.900000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] echolost transport=tmux terminal=AAAA seq=5
2026-09-22 10:00:01.000000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] echorefused terminal=CCCC reason=notshell
2026-09-22 10:00:01.100000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] echorefused terminal=- reason=malformed
2026-09-22 10:00:01.200000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] draw transport=tmux terminal=AAAA chunks=3 oldestms=14.000 newestms=2.000 parsemaxms=0.400 dropped=0 vis=1
2026-09-22 10:00:01.300000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] draw transport=tmux terminal=AAAA chunks=1 oldestms=60.000 newestms=60.000 parsemaxms=1.250 dropped=7 vis=0
2026-09-22 10:00:01.400000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] draw transport=holder terminal=BBBB chunks=2 oldestms=12.000 newestms=1.000 parsemaxms=0.300 dropped=0 vis=1
2026-09-22 10:00:01.500000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] draw transport=tmux terminal=AAAA chunks=9
this line is not ours at all
"""

# One arm, two panels: the second is a terminal nobody probed, drawing and
# echoing on its own schedule. Pooling the two is the contamination
# `--terminals` exists to remove and the per-terminal breakdown exists to show.
SELF_TEST_SECOND_TERMINAL_LINES = """\
2026-09-22 11:00:00.100000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] echo transport=tmux terminal=AAAA seq=1 ms=1.000
2026-09-22 11:00:00.200000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] echo transport=tmux terminal=AAAA seq=2 ms=2.000
2026-09-22 11:00:00.300000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] echo transport=tmux terminal=ZZZZ seq=1 ms=40.000
2026-09-22 11:00:00.400000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] echo transport=tmux terminal=ZZZZ seq=2 ms=50.000
2026-09-22 11:00:00.500000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] draw transport=tmux terminal=AAAA chunks=2 oldestms=3.000 newestms=1.000 parsemaxms=0.100 dropped=0 vis=1
2026-09-22 11:00:00.600000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] draw transport=tmux terminal=ZZZZ chunks=5 oldestms=90.000 newestms=80.000 parsemaxms=4.000 dropped=3 vis=1
"""

# A capture whose holder arm is ENTIRELY somebody else's panel: one lost token
# and one refusal, both from a terminal this run never probed. Unfiltered it is
# an arm with no samples and a lost line; filtered to AAAA the arm must vanish
# rather than print an empty distribution beside a foreign number.
SELF_TEST_FOREIGN_ARM_LINES = """\
2026-09-22 12:00:00.100000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] echo transport=tmux terminal=AAAA seq=1 ms=1.000
2026-09-22 12:00:00.200000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] echo transport=tmux terminal=AAAA seq=2 ms=2.000
2026-09-22 12:00:00.300000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] echolost transport=holder terminal=ZZZZ seq=1
2026-09-22 12:00:00.400000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] echorefused terminal=ZZZZ reason=unwritable
2026-09-22 12:00:00.500000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] echolost transport=tmux terminal=AAAA seq=3
2026-09-22 12:00:00.600000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] echorefused terminal=AAAA reason=noview
"""

# A wait cannot be negative. Two draw lines that say otherwise -- one on each
# field -- beside one ordinary line, so the check sees both that the bad lines
# are refused and that the good one still lands.
SELF_TEST_NEGATIVE_WAIT_LINES = """\
2026-09-22 13:00:00.100000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] draw transport=tmux terminal=AAAA chunks=1 oldestms=-0.250 newestms=-0.250 parsemaxms=0.100 dropped=0 vis=1
2026-09-22 13:00:00.200000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] draw transport=tmux terminal=AAAA chunks=2 oldestms=4.000 newestms=-1.000 parsemaxms=0.100 dropped=0 vis=1
2026-09-22 13:00:00.300000-0400 0x1  Default 0x0 900 0 TBDApp: (TBDApp) [com.tbd.app:terminallatency] draw transport=tmux terminal=AAAA chunks=1 oldestms=7.000 newestms=1.000 parsemaxms=0.100 dropped=0 vis=1
"""

# Engine mode: two holder terminals, SSSS on SwiftTerm and GGGG on libghostty,
# interleaved A/B/B/A with one sequence counter across both, as the driver
# runs them. ZZZZ is a third holder panel nobody probed and TTTT a tmux one;
# both must stay out of every figure. GGGG loses one token.
SELF_TEST_ENGINE_LINES = """\
2026-11-08 10:00:00.100000-0500 0x1  Info 0x0 900 0 TBDApp: [com.tbd.app:terminallatency] echo transport=holder terminal=SSSS seq=1 ms=1.000
2026-11-08 10:00:00.200000-0500 0x1  Info 0x0 900 0 TBDApp: [com.tbd.app:terminallatency] echo transport=holder terminal=GGGG seq=2 ms=0.500
2026-11-08 10:00:00.300000-0500 0x1  Info 0x0 900 0 TBDApp: [com.tbd.app:terminallatency] echo transport=holder terminal=GGGG seq=3 ms=0.700
2026-11-08 10:00:00.400000-0500 0x1  Info 0x0 900 0 TBDApp: [com.tbd.app:terminallatency] echo transport=holder terminal=SSSS seq=4 ms=3.000
2026-11-08 10:00:00.500000-0500 0x1  Info 0x0 900 0 TBDApp: [com.tbd.app:terminallatency] echo transport=holder terminal=SSSS seq=5 ms=2.000
2026-11-08 10:00:00.600000-0500 0x1  Info 0x0 900 0 TBDApp: [com.tbd.app:terminallatency] echo transport=holder terminal=GGGG seq=6 ms=3.000
2026-11-08 10:00:00.700000-0500 0x1  Info 0x0 900 0 TBDApp: [com.tbd.app:terminallatency] echo transport=holder terminal=GGGG seq=7 ms=5.000
2026-11-08 10:00:00.800000-0500 0x1  Info 0x0 900 0 TBDApp: [com.tbd.app:terminallatency] echo transport=holder terminal=SSSS seq=8 ms=4.000
2026-11-08 10:00:00.900000-0500 0x1  Info 0x0 900 0 TBDApp: [com.tbd.app:terminallatency] echo transport=holder terminal=ZZZZ seq=1 ms=90.000
2026-11-08 10:00:01.000000-0500 0x1  Info 0x0 900 0 TBDApp: [com.tbd.app:terminallatency] echo transport=tmux terminal=TTTT seq=1 ms=80.000
2026-11-08 10:00:01.100000-0500 0x1  Info 0x0 900 0 TBDApp: [com.tbd.app:terminallatency] echolost transport=holder terminal=GGGG seq=9
2026-11-08 10:00:01.200000-0500 0x1  Info 0x0 900 0 TBDApp: [com.tbd.app:terminallatency] echolost transport=holder terminal=ZZZZ seq=2
2026-11-08 10:00:01.300000-0500 0x1  Info 0x0 900 0 TBDApp: [com.tbd.app:terminallatency] draw transport=holder terminal=SSSS chunks=2 oldestms=10.000 newestms=1.000 parsemaxms=0.200 dropped=0 vis=1
2026-11-08 10:00:01.400000-0500 0x1  Info 0x0 900 0 TBDApp: [com.tbd.app:terminallatency] draw transport=holder terminal=GGGG chunks=3 oldestms=9.000 newestms=1.000 parsemaxms=0.100 dropped=0 vis=1
2026-11-08 10:00:01.500000-0500 0x1  Info 0x0 900 0 TBDApp: [com.tbd.app:terminallatency] draw transport=holder terminal=ZZZZ chunks=5 oldestms=99.000 newestms=9.000 parsemaxms=7.000 dropped=4 vis=1
2026-11-08 10:00:01.600000-0500 0x1  Info 0x0 900 0 TBDApp: [com.tbd.app:terminallatency] echorefused terminal=ZZZZ reason=noview
"""

# Engine mode's load map is keyed by engine. Each arm's first two samples at
# idle, its last two under load.
SELF_TEST_ENGINE_LOAD_MAP = {
    "swiftterm": {"1": 1.0, "4": 2.0, "5": 30.0, "8": 41.0},
    "libghostty": {"2": 1.0, "3": 2.0, "6": 30.0, "7": 41.0},
}

# seq 1-2 taken at idle, 3-4 under load, on both arms.
SELF_TEST_LOAD_MAP = {
    "tmux": {"1": 1.0, "2": 2.0, "3": 30.0, "4": 41.0},
    "holder": {"1": 1.0, "2": 2.0, "3": 30.0, "4": 41.0},
}


def self_test_draw_run() -> tuple[list[str], dict, dict]:
    """Engine-mode draw lines, load map and request times for a run of 100
    requests per arm: 90 at idle, then 10 under load, the fewest a verdict
    needs. Idle, libghostty draws in 2 ms and SwiftTerm in 5; under load,
    libghostty in 40 and SwiftTerm in 30. Pooled, libghostty's p90 is far
    below SwiftTerm's and the load-band regression vanishes; banded, it shows.

    SwiftTerm's draws also test the placement. The load of its second
    request is missing, so the draw after it joins neither band. Four more
    draws: one fed before the first request and one long after the last
    (outside the run), one with no log time, and one logged just after an
    under-load request whose chunk was fed 500 ms earlier, after the idle
    request before it. That one is idle: placed by its log time, nearest or
    latest before, it would be under load.
    """
    zone = datetime.timezone(datetime.timedelta(hours=-5))
    base = datetime.datetime(2026, 11, 8, 11, 0, 0, tzinfo=zone)
    prefix = "0x1  Info 0x0 900 0 TBDApp: [com.tbd.app:terminallatency]"

    def draw(when: datetime.datetime | None, terminal: str, wait: float) -> str:
        stamp = when.strftime("%Y-%m-%d %H:%M:%S.%f%z") if when else "x"
        return (
            f"{stamp} {prefix} draw transport=holder terminal={terminal} chunks=1"
            f" oldestms={wait:.3f} newestms={wait:.3f} parsemaxms=0.100 dropped=0 vis=1"
        )

    lines: list[str] = []
    loads: dict[str, dict[str, float]] = {"swiftterm": {}, "libghostty": {}}
    times: dict[str, dict[str, float]] = {"swiftterm": {}, "libghostty": {}}
    seq = 0
    for index in range(100):
        under_load = index >= 90
        for arm, terminal, idle_ms, load_ms in (
            ("swiftterm", "SSSS", 5.0, 30.0),
            ("libghostty", "GGGG", 2.0, 40.0),
        ):
            seq += 1
            issued = base + datetime.timedelta(seconds=seq * 0.25)
            loads[arm][str(seq)] = 30.0 if under_load else 1.0
            times[arm][str(seq)] = issued.timestamp()
            wait = load_ms if under_load else idle_ms
            # The echo comes back 3 ms after the request; its chunk then waits.
            lines.append(draw(issued + datetime.timedelta(milliseconds=3 + wait), terminal, wait))
    # SwiftTerm's last idle request is seq 179 at 44.75 s, its first under
    # load seq 181 at 45.25 s.
    lines.append(draw(base + datetime.timedelta(seconds=45.30), "SSSS", 500.0))
    lines.append(draw(base + datetime.timedelta(seconds=0.1), "SSSS", 1.0))
    lines.append(draw(base + datetime.timedelta(seconds=52.0), "SSSS", 1.0))
    lines.append(draw(None, "SSSS", 1.0))
    del loads["swiftterm"]["3"]
    return lines, loads, times


def self_test() -> int:
    import io

    failures: list[str] = []

    def check(label: str, actual, expected) -> None:
        if actual != expected:
            failures.append(f"{label}: expected {expected!r}, got {actual!r}")

    capture = parse(io.StringIO(SELF_TEST_LINES))

    check("echo count", len(capture.echoes), 8)
    check("draw count", len(capture.draws), 3)
    tmux_arm, holder_arm = transport_arms()
    check("tmux lost", capture.lost_count(tmux_arm), 1)
    check("refused notshell", capture.refusal_counts().get("notshell"), 1)
    check("refused malformed", capture.refusal_counts().get("malformed"), 1)
    # The truncated `draw ... chunks=9` line matched the verb and is counted,
    # never silently dropped; the prose line matches nothing.
    check("malformed lines", capture.malformed, 1)

    tmux_echo = sorted(e.ms for e in capture.echoes if e.transport == "tmux")
    check("tmux echo n", len(tmux_echo), 4)
    # Nearest rank over [1,2,9,11]: p50 -> rank 2, p90 -> rank 4.
    check("tmux echo p50", percentile(tmux_echo, 0.50), 2.0)
    check("tmux echo p90", percentile(tmux_echo, 0.90), 11.0)

    holder_echo = sorted(e.ms for e in capture.echoes if e.transport == "holder")
    check("holder echo p50", percentile(holder_echo, 0.50), 0.7)
    check("holder echo p90", percentile(holder_echo, 0.90), 1.1)

    # Banding: idle = seqs 1-2, load = seqs 3-4, against --idle-max 8.
    def band(transport: str, load_map: dict, over: bool) -> list[float]:
        out: list[float] = []
        for echo in capture.echoes:
            if echo.transport != transport:
                continue
            load = load_for(load_map, transport, echo.seq)
            if load is None:
                continue
            if (load > 8) == over:
                out.append(echo.ms)
        return sorted(out)

    idle = band("tmux", SELF_TEST_LOAD_MAP, over=False)
    load = band("tmux", SELF_TEST_LOAD_MAP, over=True)
    check("tmux idle band", idle, [1.0, 2.0])
    check("tmux load band", load, [9.0, 11.0])
    check("tmux flatness", round(percentile(load, 0.90) / percentile(idle, 0.90), 3), 5.5)

    check("missing load entry is None", load_for(SELF_TEST_LOAD_MAP, "tmux", 99), None)
    check("missing arm is None", load_for(SELF_TEST_LOAD_MAP, "nope", 1), None)
    check("no load map is None", load_for(None, "tmux", 1), None)

    # A negative wait is impossible, so it is refused rather than reported:
    # flooring it to 0 would put a fabricated sample in the distribution, and
    # the p50 of [0, 7] is 0 where the p50 of [7] is 7.
    negative = parse(io.StringIO(SELF_TEST_NEGATIVE_WAIT_LINES))
    check("negative waits refused", negative.negative_waits, 2)
    check("surviving draws", [d.oldest_ms for d in negative.draws], [7.0])
    check("a negative wait is not counted as a format drift", negative.malformed, 0)
    negative_out = io.StringIO()
    report(negative, out=negative_out)
    negative_text = negative_out.getvalue()
    for needle in ("2 draw line(s) reported a negative wait", "p50=   7.000"):
        if needle not in negative_text:
            failures.append(f"negative-wait report is missing {needle!r}")

    # Percentile edge: n=100 must not put p99 on the maximum.
    hundred = [float(i) for i in range(1, 101)]
    check("p99 of 1..100", percentile(hundred, 0.99), 99.0)
    check("p50 of 1..100", percentile(hundred, 0.50), 50.0)

    # The reporter runs end to end and says what the run decided, including
    # both verdict lines for the arm that breaches them and the arm that does
    # not.
    buffer = io.StringIO()
    report(capture, out=buffer, idle_max=8.0, load_map=SELF_TEST_LOAD_MAP)
    text = buffer.getvalue()
    for needle in (
        "tmux flatness",
        "5.50x (OVER the 2x bound)",
        "p90 under load = 11.000 ms (OVER the 5 ms bound)",
        "holder flatness",
        "1.57x (WITHIN the 2x bound)",
        "p90 under load = 1.100 ms (WITHIN the 5 ms bound)",
        "tmux on screen",
        "tmux all draws",
        "1 token(s) never came back",
        "notshell",
        "4 fed, 7 dropped past the ring, worst parse 1.250 ms",
        "the emitted format and this parser have drifted apart",
    ):
        if needle not in text:
            failures.append(f"report output is missing {needle!r}")

    # With no load map the banded lines must be absent rather than empty.
    plain = io.StringIO()
    report(capture, out=plain)
    if "flatness" in plain.getvalue():
        failures.append("unbanded report printed a flatness line")

    # A sample whose load was never recorded is in NEITHER band. Dropping
    # tmux seq 4 (11.000 ms, taken under load) from the map leaves the load
    # band [9.000] and the idle band untouched: counting the unknown as idle
    # would put 11.000 in the DENOMINATOR and report 0.82x WITHIN.
    partial_map = {
        "tmux": {"1": 1.0, "2": 2.0, "3": 30.0},
        "holder": SELF_TEST_LOAD_MAP["holder"],
    }
    unknown_out = io.StringIO()
    report(capture, out=unknown_out, idle_max=8.0, load_map=partial_map)
    unknown_text = unknown_out.getvalue()
    for needle in (
        "tmux unbanded          no load recorded: 1 (excluded from both bands)",
        "holder unbanded        no load recorded: 0 (excluded from both bands)",
        "4.50x (OVER the 2x bound)",
        "p90 under load = 9.000 ms (OVER the 5 ms bound)",
    ):
        if needle not in unknown_text:
            failures.append(f"unknown-load report is missing {needle!r}")
    if "0.82x" in unknown_text:
        failures.append("an unknown-load sample was banded as idle")

    # A capture taken entirely under load -- an arm that never saw an idle
    # minute -- still answers the absolute bound, and must. The flatness ratio
    # has no denominator here and must stay absent rather than be invented.
    load_only_map = {
        "tmux": {"1": 30.0, "2": 31.0, "3": 32.0, "4": 33.0},
        "holder": {"1": 30.0, "2": 31.0, "3": 32.0, "4": 33.0},
    }
    load_only = io.StringIO()
    report(capture, out=load_only, idle_max=8.0, load_map=load_only_map)
    load_only_text = load_only.getvalue()
    for needle in (
        "p90 under load = 11.000 ms (OVER the 5 ms bound)",
        "p90 under load = 1.100 ms (WITHIN the 5 ms bound)",
        "tmux idle              (no samples)",
    ):
        if needle not in load_only_text:
            failures.append(f"load-only report is missing {needle!r}")
    if "flatness" in load_only_text:
        failures.append("a load-only capture printed a flatness ratio with no idle band")

    # The driver's incomplete banner reaches the reader through the header,
    # above every figure.
    noted = io.StringIO()
    report(capture, out=noted, note="INTERRUPTED -- tmux answered 4 of 5")
    if "INTERRUPTED -- tmux answered 4 of 5" not in noted.getvalue():
        failures.append("report did not print the caller's note")

    # Terminals: unfiltered, a second panel on the same arm is broken out;
    # filtered, it is gone from both the echo and the draw figures.
    contaminated = parse(io.StringIO(SELF_TEST_SECOND_TERMINAL_LINES))
    check("second-terminal echo count", len(contaminated.echoes), 4)

    pooled = io.StringIO()
    report(contaminated, out=pooled)
    pooled_text = pooled.getvalue()
    for needle in ("tmux AAAA", "tmux ZZZZ", "tmux all               n=4"):
        if needle not in pooled_text:
            failures.append(f"unfiltered report is missing {needle!r}")

    filtered = io.StringIO()
    # Lowercase on purpose: the app emits uppercase UUIDs, and an id typed by
    # hand must still match. It is echoed back as typed.
    report(contaminated, out=filtered, terminals={"aaaa"})
    filtered_text = filtered.getvalue()
    if "ZZZZ" in filtered_text:
        failures.append("--terminals did not exclude the other terminal")
    for needle in ("only terminals: aaaa", "tmux all               n=2", "2 fed, 0 dropped"):
        if needle not in filtered_text:
            failures.append(f"filtered report is missing {needle!r}")

    # Lost tokens and refusals are this run's only when they name this run's
    # terminals. Unfiltered, the holder arm is present on the strength of a
    # foreign lost line alone -- which is what printed `(no samples)` beside
    # somebody else's number.
    foreign = parse(io.StringIO(SELF_TEST_FOREIGN_ARM_LINES))
    check("foreign lost records", len(foreign.lost), 2)
    check("foreign lost, unfiltered", foreign.lost_count(holder_arm), 1)
    check("foreign lost, filtered out", foreign.lost_count(holder_arm, {"aaaa"}), 0)
    check("own lost, filtered in", foreign.lost_count(tmux_arm, {"aaaa"}), 1)
    check("foreign refusal, unfiltered", foreign.refusal_counts().get("unwritable"), 1)
    check("foreign refusal, filtered out", foreign.refusal_counts({"aaaa"}).get("unwritable"), None)
    check("own refusal, filtered in", foreign.refusal_counts({"aaaa"}).get("noview"), 1)

    unfiltered_foreign = io.StringIO()
    report(foreign, out=unfiltered_foreign)
    unfiltered_foreign_text = unfiltered_foreign.getvalue()
    for needle in ("holder all", "(no samples)", "unwritable"):
        if needle not in unfiltered_foreign_text:
            failures.append(f"unfiltered foreign-arm report is missing {needle!r}")

    filtered_foreign = io.StringIO()
    report(foreign, out=filtered_foreign, terminals={"AAAA"})
    filtered_foreign_text = filtered_foreign.getvalue()
    for absent in ("holder", "(no samples)", "unwritable"):
        if absent in filtered_foreign_text:
            failures.append(
                f"a foreign terminal's {absent!r} survived --terminals"
            )
    for needle in ("tmux all", "1 token(s) never came back", "noview"):
        if needle not in filtered_foreign_text:
            failures.append(f"filtered foreign-arm report is missing {needle!r}")

    # Transport mode never prints engine mode's header, arms line or
    # comparison, whatever it is given.
    for absent in ("ENGINES", "arms:", "terminal engine latency", "swiftterm", "libghostty"):
        if absent in text:
            failures.append(f"a transport-mode report printed engine mode's {absent!r}")

    # Engine mode: both arms are holder terminals, so a line is an arm's by its
    # id alone. Lowercase ids on purpose: the app emits uppercase, and the
    # arms line echoes them as given.
    engine_capture = parse(io.StringIO(SELF_TEST_ENGINE_LINES))
    check("engine echo count", len(engine_capture.echoes), 10)
    arms = engine_arms("ssss", "gggg")
    check("engine arm labels", [arm.label for arm in arms], list(ENGINES))
    check("engine arms share the holder transport", {arm.transport for arm in arms}, {"holder"})
    check("swiftterm arm owns SSSS", arms[0].owns(engine_capture.echoes[0]), True)
    check("libghostty arm does not own SSSS", arms[1].owns(engine_capture.echoes[0]), False)
    check("libghostty lost", engine_capture.lost_count(arms[1], {"ssss", "gggg"}), 1)
    check("swiftterm lost", engine_capture.lost_count(arms[0], {"ssss", "gggg"}), 0)

    engine_out = io.StringIO()
    report(engine_capture, out=engine_out, idle_max=8.0, load_map=SELF_TEST_ENGINE_LOAD_MAP, arms=arms)
    engine_text = engine_out.getvalue()
    for needle in (
        "terminal engine latency, milliseconds",
        "(the same loop on both engines: the check)",
        "(compares engines)",
        "arms: swiftterm = ssss, libghostty = gggg",
        "swiftterm all          n=4      p50=   2.000 p90=   4.000",
        "libghostty all         n=4",
        "libghostty lost        1 token(s) never came back",
        "swiftterm idle         n=2",
        "libghostty load        n=2",
        "swiftterm unbanded     no load recorded: 0 (excluded from both bands)",
        "swiftterm flatness     p90 load / p90 idle = 1.33x (WITHIN the 2x bound)",
        "libghostty flatness    p90 load / p90 idle = 7.14x (OVER the 2x bound)",
        "swiftterm absolute     p90 under load = 4.000 ms (WITHIN the 5 ms bound)",
        "libghostty absolute    p90 under load = 5.000 ms (WITHIN the 5 ms bound)",
        "swiftterm on screen",
        "libghostty on screen",
        "libghostty chunks      3 fed, 0 dropped past the ring",
        "ENGINES (p90, libghostty / swiftterm",
        "a verdict needs 10 samples an arm)",
        # Two samples a band: the ratio prints, the verdict does not.
        "echo idle              libghostty 0.700 (n=2) / swiftterm 3.000 (n=2) = 0.233x"
        " (too few samples; no verdict)",
        "echo load              libghostty 5.000 (n=2) / swiftterm 4.000 (n=2) = 1.250x"
        " (too few samples; no verdict)",
        # No request times, so the draws are not banded and get no verdict.
        "draw on screen         libghostty 9.000 (n=1) / swiftterm 10.000 (n=1) = 0.900x"
        " (not banded: no request times; no verdict)",
    ):
        if needle not in engine_text:
            failures.append(f"engine report is missing {needle!r}")
    for absent in ("draw idle", "draw load", "draw bands"):
        if absent in engine_text:
            failures.append(f"an engine report with no request times printed {absent!r}")
    # The third holder panel, the tmux panel, and their lost token and
    # refusal are another panel's traffic, and transport labels have no place.
    for absent in ("90.000", "80.000", "99.000", "ZZZZ", "TTTT", "noview", "holder ", "tmux "):
        if absent in engine_text:
            failures.append(f"engine report printed {absent!r}")

    # Unbanded, the comparison sets the pooled figures side by side, with no
    # verdict on either measure.
    engine_plain = io.StringIO()
    report(engine_capture, out=engine_plain, arms=arms)
    engine_plain_text = engine_plain.getvalue()
    for needle in (
        "echo all               libghostty 5.000 (n=4) / swiftterm 4.000 (n=4) = 1.250x"
        " (not banded: no load map; no verdict)",
        "draw on screen         libghostty 9.000 (n=1) / swiftterm 10.000 (n=1) = 0.900x"
        " (not banded: no load map; no verdict)",
    ):
        if needle not in engine_plain_text:
            failures.append(f"unbanded engine report is missing {needle!r}")
    for absent in ("echo idle", "echo load", "flatness", "MEETS", "SHORT", "higher"):
        if absent in engine_plain_text:
            failures.append(f"unbanded engine report printed {absent!r}")

    # Draws banded by time. Pooled, libghostty's p90 would MEET the bar
    # while hiding a regression under load.
    draw_lines, draw_loads, draw_times = self_test_draw_run()
    draw_capture = parse(io.StringIO("\n".join(draw_lines) + "\n"))
    check("timed draws", sum(d.at is not None for d in draw_capture.draws), len(draw_lines) - 1)
    draw_arms = engine_arms("SSSS", "GGGG")
    drawn = io.StringIO()
    report(
        draw_capture, out=drawn, idle_max=8.0, load_map=draw_loads, arms=draw_arms,
        request_times=draw_times,
    )
    drawn_text = drawn.getvalue()
    for needle in (
        "swiftterm draw idle    n=90",
        "swiftterm draw load    n=10 ",
        "swiftterm draw bands   in neither band: 4"
        " (2 outside the run, 1 no load recorded, 1 no log time)",
        "libghostty draw idle   n=90",
        "libghostty draw bands  in neither band: 0",
        "draw idle              libghostty 2.000 (n=90) / swiftterm 5.000 (n=90) = 0.400x"
        " (libghostty 60% lower: MEETS the 20% bar)",
        # Ten samples a band is enough for a verdict.
        "draw load              libghostty 40.000 (n=10) / swiftterm 30.000 (n=10) = 1.333x"
        " (libghostty 33% higher)",
    ):
        if needle not in drawn_text:
            failures.append(f"banded draw report is missing {needle!r}")
    if "draw on screen         libghostty" in drawn_text:
        failures.append("a banded draw report printed a pooled draw comparison")
    swiftterm_visible = [d for d in draw_capture.draws if d.terminal == "SSSS" and d.visible]
    late_idle, late_load, _ = split_draw_bands(
        swiftterm_visible, "swiftterm", 8.0, draw_loads, draw_times
    )
    check("a draw goes by its feed time to the request before it", (500.0 in late_idle, 500.0 in late_load), (True, False))
    check(
        "an arm with no request times places nothing",
        split_draw_bands(swiftterm_visible, "swiftterm", 8.0, draw_loads, {"libghostty": draw_times["libghostty"]})[2],
        {"no request times": len(swiftterm_visible) - 1, "no log time": 1},
    )
    # Transport mode reads no request times and prints no draw band.
    for absent in ("draw idle", "draw bands"):
        if absent in text:
            failures.append(f"a transport-mode report printed {absent!r}")

    # SwiftTerm under its Metal renderer emits no draw lines: the comparison
    # says there is nothing to compare rather than inventing a ratio.
    metal = parse(
        io.StringIO(
            "".join(
                line + "\n"
                for line in SELF_TEST_ENGINE_LINES.splitlines()
                if not ("draw " in line and "terminal=SSSS" in line)
            )
        )
    )
    metal_out = io.StringIO()
    report(metal, out=metal_out, arms=arms)
    if "draw on screen         libghostty n=1 / swiftterm n=0 (no samples on one arm)" not in metal_out.getvalue():
        failures.append("engine report invented a draw comparison with one arm empty")

    # The bar is inclusive. The verdict is the printed ratio's, and the
    # percentage rounds down, so neither can contradict the other.
    for ghostty_p90, expected in (
        (0.8, "0.800x (libghostty 20% lower: MEETS the 20% bar)"),
        (0.8004, "0.800x (libghostty 20% lower: MEETS the 20% bar)"),
        (0.8049, "0.805x (libghostty 19% lower: SHORT of the 20% bar)"),
        (0.81, "0.810x (libghostty 19% lower: SHORT of the 20% bar)"),
        (0.2336, "0.234x (libghostty 76% lower: MEETS the 20% bar)"),
        (0.9995, "1.000x (no difference)"),
        (0.999, "0.999x (libghostty under 1% lower: SHORT of the 20% bar)"),
        (1.0059, "1.006x (libghostty under 1% higher)"),
        (1.0199, "1.020x (libghostty 2% higher)"),
    ):
        line = engine_comparison_line("x", [ghostty_p90] * ENGINE_MIN_SAMPLES, [1.0] * ENGINE_MIN_SAMPLES)
        check(f"ratio line for {ghostty_p90}", line.split(" = ", 1)[-1], expected)
    # Below the floor on either arm the ratio prints and the verdict does not.
    floor = ENGINE_MIN_SAMPLES
    for ghostty_n, swiftterm_n, expected in (
        (floor - 1, floor, "0.500x (too few samples; no verdict)"),
        (floor, floor - 1, "0.500x (too few samples; no verdict)"),
        (floor, floor, "0.500x (libghostty 50% lower: MEETS the 20% bar)"),
    ):
        line = engine_comparison_line("x", [0.5] * ghostty_n, [1.0] * swiftterm_n)
        check(f"verdict at n={ghostty_n}/{swiftterm_n}", line.split(" = ", 1)[-1], expected)
        check(f"counts at n={ghostty_n}/{swiftterm_n}", f"(n={ghostty_n}) / swiftterm 1.000 (n={swiftterm_n})" in line, True)
    # The arms are refused alongside `terminals`.
    try:
        report(engine_capture, out=io.StringIO(), terminals={"ssss"}, arms=arms)
        failures.append("report accepted engine arms together with terminals")
    except ValueError:
        pass

    if failures:
        for failure in failures:
            print(f"FAIL {failure}", file=sys.stderr)
        print(f"{len(failures)} self-test failure(s)", file=sys.stderr)
        return 1
    print("terminal-latency-report self-test: OK")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Report TBD's terminal transport latency from a `log show` capture.",
        epilog="All figures are milliseconds.",
    )
    parser.add_argument("logfile", nargs="?", help="`log show` output; defaults to stdin.")
    parser.add_argument(
        "--load-map",
        help="JSON of {'<arm>': {'<seq>': <load1>}} written by the driver script."
        " An arm is a transport, or in engine mode an engine. An engine-mode map also"
        " carries 'times': {'<arm>': {'<seq>': <epoch seconds>}}, which bands the draws.",
    )
    parser.add_argument(
        "--idle-max",
        type=float,
        help="1-minute load at or below which a sample counts as idle. Needs --load-map.",
    )
    parser.add_argument(
        "--terminals",
        help="Comma-separated terminal ids to restrict echo AND draw figures to."
        " Compared case-insensitively. Omit for a per-terminal breakdown instead.",
    )
    parser.add_argument(
        "--swiftterm-terminal",
        help="Engine mode: the holder terminal on SwiftTerm, reported as the swiftterm arm."
        " Needs --ghostty-terminal.",
    )
    parser.add_argument(
        "--ghostty-terminal",
        help="Engine mode: the holder terminal on libghostty, reported as the libghostty arm."
        " Needs --swiftterm-terminal.",
    )
    parser.add_argument("--self-test", action="store_true", help="Run the fixture self-test.")
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    if (args.idle_max is None) != (args.load_map is None):
        print(
            "--idle-max and --load-map go together: a band needs both a threshold"
            " and a per-sample load.",
            file=sys.stderr,
        )
        return 2

    arms: list[Arm] | None = None
    if args.swiftterm_terminal is not None or args.ghostty_terminal is not None:
        if not args.swiftterm_terminal or not args.ghostty_terminal:
            print(
                "--swiftterm-terminal and --ghostty-terminal go together: an engine"
                " comparison needs one terminal on each engine.",
                file=sys.stderr,
            )
            return 2
        if args.swiftterm_terminal.lower() == args.ghostty_terminal.lower():
            print(
                "--swiftterm-terminal and --ghostty-terminal name the same terminal.",
                file=sys.stderr,
            )
            return 2
        if args.terminals:
            print(
                "--terminals cannot be combined with engine mode, which already"
                " restricts every figure to its two terminals.",
                file=sys.stderr,
            )
            return 2
        arms = engine_arms(args.swiftterm_terminal, args.ghostty_terminal)

    load_map = None
    request_times = None
    if args.load_map:
        with open(args.load_map, encoding="utf-8") as handle:
            load_map = json.load(handle)
        # Not an arm: when each request was issued, which the draws are
        # banded by. Only an engine-mode map carries it.
        request_times = load_map.pop(REQUEST_TIMES_KEY, None)

    terminals: set[str] | None = None
    if args.terminals:
        terminals = {part.strip() for part in args.terminals.split(",") if part.strip()}
        if not terminals:
            print("--terminals was given but named no terminal.", file=sys.stderr)
            return 2

    stream = open(args.logfile, encoding="utf-8") if args.logfile else sys.stdin
    try:
        capture = parse(stream)
    finally:
        if args.logfile:
            stream.close()

    if not capture.echoes and not capture.draws:
        print("No terminal latency lines found.", file=sys.stderr)
        print(
            "Is `defaults write com.github.cheapsteak.tbd enableTerminalLatencyDiagnostic"
            " -bool true` set (the TBDApp domain for an unbundled `swift run` build),"
            " and did the app relaunch after? `log show` also needs --info.",
            file=sys.stderr,
        )
        return 1

    report(
        capture,
        idle_max=args.idle_max,
        load_map=load_map,
        terminals=terminals,
        arms=arms,
        request_times=request_times,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
