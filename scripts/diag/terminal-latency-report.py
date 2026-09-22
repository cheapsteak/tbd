#!/usr/bin/env python3
"""Turn a `log show` capture of TBD's terminal latency lines into the table.

WHAT THE NUMBERS ARE
--------------------
Two instruments, measured inside TBDApp, on both terminal transports, by one
mechanism (`Sources/TBDApp/Terminal/TerminalLatencyTap.swift`):

  echo  -- a token written through a panel's REAL keystroke path, stamped
           again when its first copy comes back at the app's feed seam. The
           loop spans the pty, the line discipline, and on tmux the server, so
           this is the transport's number and it is the only one here that
           compares the two arms.

  draw  -- how long the OLDEST chunk in a frame sat parsed-but-undrawn before
           that panel's view started drawing. Identical in mechanism on both
           arms, because both feed through the same line of code. It cannot
           see anything BEFORE the app's read -- which is precisely where tmux
           sits -- so it never compares transports by itself.

THE DRAW LINE IS THE CHECK ON THE ECHO LINE, AND THAT IS WHY BOTH PRINT
----------------------------------------------------------------------
If the two arms' draw waits agree and their echoes differ, the difference is
upstream of the app: the transport. If the draw waits DISAGREE, the arms are
not being measured the same way and the echo comparison is suspect. Both are
printed so that check is always in front of you rather than optional.

WHAT IT CANNOT SHOW
-------------------
- Pixels. The draw endpoint is the START of a draw; the commit probe covers
  the app-side commit and nothing covers the compositor.
- An agent's response. `cat` echo is the line discipline (or tmux) answering,
  not a TUI repainting. It says nothing about how fast Claude Code redraws.
- A fair comparison without a fair run. On this machine a load swing from 7 to
  139 once faked a threefold effect that vanished under matched load, so
  samples are never pooled across load bands: pass `--load-map` and
  `--idle-max` and the echo figures split into idle and load.
- Anything under the Metal renderer (`viewWillDraw` is not on that frame
  path, so no draw lines are emitted at all) or on the control-mode attach
  path.

THE VERDICT LINES
-----------------
The pty-holder transport spec's Rollout section makes graduation depend on a
paired measurement: p90 keystroke echo at load no more than 2x p90 at idle,
and no more than 5 ms. With `--load-map` and `--idle-max` this script prints
both comparisons per transport. It supplies the numbers; the verdict over the
spec's four conditions (workload, sample size, absolute bound, flatness bound)
is a human judgement.

USAGE
-----
    defaults write TBDApp enableTerminalLatencyDiagnostic -bool true
    # relaunch TBDApp (scripts/restart.sh), then drive a run:
    scripts/diag/terminal-latency-probe.py --worktree <name>

    # or read a capture by hand:
    log show --last 10m --info \\
      --predicate 'subsystem == "com.tbd.app" AND category == "terminallatency"' \\
      | scripts/diag/terminal-latency-report.py

    scripts/diag/terminal-latency-report.py --self-test
"""

from __future__ import annotations

import argparse
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

TRANSPORTS = ("tmux", "holder")


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


@dataclass(slots=True)
class Capture:
    echoes: list[Echo] = field(default_factory=list)
    draws: list[Draw] = field(default_factory=list)
    # transport -> count
    lost: dict[str, int] = field(default_factory=dict)
    # reason -> count
    refused: dict[str, int] = field(default_factory=dict)
    # Lines that matched the verb but not the fields they must carry. Counted
    # rather than dropped: a format drift must be visible, not silent.
    malformed: int = 0


def parse_fields(blob: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for token in blob.split():
        key, _, value = token.partition("=")
        if value:
            out[key] = value
    return out


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
                capture.draws.append(
                    Draw(
                        transport=fields["transport"],
                        terminal=fields["terminal"],
                        chunks=int(fields["chunks"]),
                        oldest_ms=float(fields["oldestms"]),
                        newest_ms=float(fields["newestms"]),
                        parse_max_ms=float(fields["parsemaxms"]),
                        dropped=int(fields["dropped"]),
                        visible=fields["vis"] == "1",
                    )
                )
            elif verb == "echolost":
                transport = fields["transport"]
                capture.lost[transport] = capture.lost.get(transport, 0) + 1
            elif verb == "echorefused":
                reason = fields["reason"]
                capture.refused[reason] = capture.refused.get(reason, 0) + 1
        except (KeyError, ValueError):
            capture.malformed += 1
    return capture


def percentile(values: list[float], fraction: float) -> float:
    """Nearest-rank percentile, rank = ceil(p*n), clamped. `values` sorted.

    `ceil`, not `round(p*n + 0.5)`: Python rounds half to even, so that form
    overshoots -- at n=100 it puts p99 on rank 100, reporting the maximum.
    Matches `commit-latency-report.py` and the daemon's InputLatencyRecorder.
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


def load_for(load_map: dict | None, transport: str, seq: int) -> float | None:
    """The 1-minute load average recorded alongside one sample.

    Shape, as the driver writes it: {"<transport>": {"<seq>": <load>}}. JSON
    object keys are strings, so the sequence number is looked up as one.
    """
    if not load_map:
        return None
    arm = load_map.get(transport)
    if not arm:
        return None
    value = arm.get(str(seq))
    return None if value is None else float(value)


def report(
    capture: Capture,
    out=sys.stdout,
    idle_max: float | None = None,
    load_map: dict | None = None,
) -> None:
    print("terminal transport latency, milliseconds", file=out)
    print(
        "echo = keystroke round trip through the real input path (compares transports)",
        file=out,
    )
    print(
        "draw = oldest chunk's wait before its panel drew (does NOT compare transports)",
        file=out,
    )
    if capture.malformed:
        print(
            f"\n!! {capture.malformed} line(s) carried the verb but not its fields --"
            " the emitted format and this parser have drifted apart.",
            file=out,
        )

    banded = idle_max is not None and load_map is not None

    print("\nECHO", file=out)
    for transport in TRANSPORTS:
        samples = [e for e in capture.echoes if e.transport == transport]
        if not samples and not capture.lost.get(transport):
            continue
        print(format_distribution(f"{transport} all", distribution([e.ms for e in samples])), file=out)
        lost = capture.lost.get(transport, 0)
        if lost:
            print(f"  {transport + ' lost':<22} {lost} token(s) never came back", file=out)
        if not banded:
            continue
        idle = [e.ms for e in samples if (load_for(load_map, transport, e.seq) or 0.0) <= idle_max]
        under_load = [
            e.ms
            for e in samples
            if load_for(load_map, transport, e.seq) is not None
            and load_for(load_map, transport, e.seq) > idle_max
        ]
        print(format_distribution(f"{transport} idle", distribution(idle)), file=out)
        print(format_distribution(f"{transport} load", distribution(under_load)), file=out)
        if idle and under_load:
            idle_p90 = percentile(sorted(idle), 0.90)
            load_p90 = percentile(sorted(under_load), 0.90)
            ratio = load_p90 / idle_p90 if idle_p90 else float("inf")
            flat = "WITHIN" if ratio <= 2.0 else "OVER"
            print(
                f"  {transport + ' flatness':<22} p90 load / p90 idle = {ratio:.2f}x"
                f" ({flat} the 2x bound)",
                file=out,
            )
            bound = "WITHIN" if load_p90 <= 5.0 else "OVER"
            print(
                f"  {transport + ' absolute':<22} p90 under load = {load_p90:.3f} ms"
                f" ({bound} the 5 ms bound)",
                file=out,
            )

    if capture.refused:
        print("\nREFUSED", file=out)
        for reason in sorted(capture.refused):
            print(f"  {reason:<22} {capture.refused[reason]}", file=out)

    print("\nDRAW (oldest chunk's wait)", file=out)
    for transport in TRANSPORTS:
        arm = [d for d in capture.draws if d.transport == transport]
        if not arm:
            continue
        visible = [d for d in arm if d.visible]
        # On-screen first, because a panel the user never sees is work nobody
        # waited for; the all-draws line is kept beside it so an arm that drew
        # mostly off-screen cannot look like an arm that barely drew.
        print(
            format_distribution(
                f"{transport} on screen", distribution([d.oldest_ms for d in visible])
            ),
            file=out,
        )
        print(
            format_distribution(
                f"{transport} all draws", distribution([d.oldest_ms for d in arm])
            ),
            file=out,
        )
        parse_max = max((d.parse_max_ms for d in arm), default=0.0)
        dropped = sum(d.dropped for d in arm)
        chunks = sum(d.chunks for d in arm)
        print(
            f"  {transport + ' chunks':<22} {chunks} fed, {dropped} dropped past the ring,"
            f" worst parse {parse_max:.3f} ms",
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

# seq 1-2 taken at idle, 3-4 under load, on both arms.
SELF_TEST_LOAD_MAP = {
    "tmux": {"1": 1.0, "2": 2.0, "3": 30.0, "4": 41.0},
    "holder": {"1": 1.0, "2": 2.0, "3": 30.0, "4": 41.0},
}


def self_test() -> int:
    import io

    failures: list[str] = []

    def check(label: str, actual, expected) -> None:
        if actual != expected:
            failures.append(f"{label}: expected {expected!r}, got {actual!r}")

    capture = parse(io.StringIO(SELF_TEST_LINES))

    check("echo count", len(capture.echoes), 8)
    check("draw count", len(capture.draws), 3)
    check("tmux lost", capture.lost.get("tmux"), 1)
    check("refused notshell", capture.refused.get("notshell"), 1)
    check("refused malformed", capture.refused.get("malformed"), 1)
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
    idle = sorted(
        e.ms
        for e in capture.echoes
        if e.transport == "tmux" and load_for(SELF_TEST_LOAD_MAP, "tmux", e.seq) <= 8
    )
    load = sorted(
        e.ms
        for e in capture.echoes
        if e.transport == "tmux" and load_for(SELF_TEST_LOAD_MAP, "tmux", e.seq) > 8
    )
    check("tmux idle band", idle, [1.0, 2.0])
    check("tmux load band", load, [9.0, 11.0])
    check("tmux flatness", round(percentile(load, 0.90) / percentile(idle, 0.90), 3), 5.5)

    check("missing load entry is None", load_for(SELF_TEST_LOAD_MAP, "tmux", 99), None)
    check("missing arm is None", load_for(SELF_TEST_LOAD_MAP, "nope", 1), None)
    check("no load map is None", load_for(None, "tmux", 1), None)

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
        help="JSON of {'<transport>': {'<seq>': <load1>}} written by the driver script.",
    )
    parser.add_argument(
        "--idle-max",
        type=float,
        help="1-minute load at or below which a sample counts as idle. Needs --load-map.",
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

    load_map = None
    if args.load_map:
        with open(args.load_map, encoding="utf-8") as handle:
            load_map = json.load(handle)

    stream = open(args.logfile, encoding="utf-8") if args.logfile else sys.stdin
    try:
        capture = parse(stream)
    finally:
        if args.logfile:
            stream.close()

    if not capture.echoes and not capture.draws:
        print("No terminal latency lines found.", file=sys.stderr)
        print(
            "Is `defaults write TBDApp enableTerminalLatencyDiagnostic -bool true` set,"
            " and did the app relaunch after? `log show` also needs --info.",
            file=sys.stderr,
        )
        return 1

    report(capture, idle_max=args.idle_max, load_map=load_map)
    return 0


if __name__ == "__main__":
    sys.exit(main())
