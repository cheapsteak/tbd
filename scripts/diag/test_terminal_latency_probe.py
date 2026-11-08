"""Tests for `terminal-latency-probe.py`, the latency run's driver.

They cover the arguments of both modes, the daemon-row refusals, engine
mode's check of each arm's engine against canned `log show --style ndjson`
lines, the A/B/B/A request order, and whole engine-mode runs with every
outside call replaced. Nothing here reaches `tbd`, `log`, `pgrep`, `ps` or a
running app. Request files go to a temp directory.

    python3 -I -m unittest discover -s scripts/diag -p 'test_terminal_latency_probe.py'

The report's own fixtures, engine-mode labels included, are its `--self-test`.
"""

from __future__ import annotations

import contextlib
import datetime
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent


def _load_probe():
    # Registered before `exec_module`, for the reason `load_report_module`
    # gives: a dataclass resolves its module out of `sys.modules`.
    spec = importlib.util.spec_from_file_location(
        "terminal_latency_probe", HERE / "terminal-latency-probe.py"
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules["terminal_latency_probe"] = module
    spec.loader.exec_module(module)
    return module


probe = _load_probe()
report = probe.load_report_module()

PID = 900
SWIFTTERM_ID = "5A5A5A5A-0000-4000-8000-000000000001"
GHOSTTY_ID = "6B6B6B6B-0000-4000-8000-000000000002"
TMUX_ID = "7C7C7C7C-0000-4000-8000-000000000003"
AGENT_ID = "8D8D8D8D-0000-4000-8000-000000000004"
ENGINE_TERMINALS = {"swiftterm": SWIFTTERM_ID, "libghostty": GHOSTTY_ID}
BASE = datetime.datetime(2026, 11, 8, 10, 0, 0, tzinfo=datetime.timezone(datetime.timedelta(hours=-5)))


def at(seconds: float) -> datetime.datetime:
    return BASE + datetime.timedelta(seconds=seconds)


def record(when: float, message: str, level: str = "Default", category: str = "terminalEngine", pid: int = PID) -> str:
    """One line as `log show --style ndjson` prints it, cut to the fields read."""
    return json.dumps({
        "timestamp": at(when).strftime("%Y-%m-%d %H:%M:%S.%f%z"),
        "messageType": level,
        "subsystem": "com.tbd.app",
        "category": category,
        "processID": pid,
        "eventMessage": message,
    })


def active(when: float, terminal: str, **kwargs) -> str:
    return record(when, f"libghostty engine active for {terminal}", **kwargs)


def switch(when: float, terminal: str, source: str, target: str, **kwargs) -> str:
    message = f"switching terminal engine terminal={terminal} from={source} to={target} override={target}"
    return record(when, message, level="Info", **kwargs)


def fallback(when: float) -> str:
    return record(when, "libghostty engine unavailable, fell back to SwiftTerm: no Metal device")


def heartbeats(start: float, stop: float) -> list[str]:
    message = "heartbeat policy=0 windows=2 active=true keyWindow=true"
    return [
        record(when, message, level="Info", category="lifecycle")
        for when in range(int(start), int(stop) + 1, 5)
    ]


# The setup the docstring asks for: both terminals opened on libghostty, then
# ⌃⌘E in the one that becomes the SwiftTerm arm.
STANDARD_ENGINE_LINES = [
    active(10, SWIFTTERM_ID),
    active(11, GHOSTTY_ID),
    switch(20, SWIFTTERM_ID, "ghostty", "swiftTerm"),
]


class FakeLog:
    """`read_app_log`'s stand-in: canned ndjson, filtered to the asked window
    and category as `log show` would."""

    def __init__(self, engine: list[str], lifecycle: list[str] | None = None) -> None:
        self.engine = list(engine)
        self.lifecycle = heartbeats(0, 3600) if lifecycle is None else list(lifecycle)
        self.calls: list[tuple[str, datetime.datetime, datetime.datetime | None]] = []

    def __call__(self, category, start, end):
        self.calls.append((category, start, end))
        source = self.engine if category == "terminalEngine" else self.lifecycle
        kept = []
        for line in source:
            when = datetime.datetime.strptime(json.loads(line)["timestamp"], "%Y-%m-%d %H:%M:%S.%f%z")
            if when >= start and (end is None or when <= end):
                kept.append(line)
        return "\n".join(kept) + "\n"


def refusal(test: unittest.TestCase, terminals: dict[str, str], log: FakeLog) -> str:
    with test.assertRaises(SystemExit) as raised:
        probe.confirm_engines(terminals, PID, at(-60), log)
    return str(raised.exception.code)


class ArgumentTests(unittest.TestCase):
    def parse_error(self, argv: list[str]) -> str:
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit) as raised:
            probe.parse_args(argv)
        self.assertEqual(raised.exception.code, 2)
        return stderr.getvalue()

    def test_transport_mode(self):
        args = probe.parse_args(["--worktree", "w", "--tmux-terminal", TMUX_ID, "--holder-terminal", GHOSTTY_ID])
        self.assertEqual(args.mode, "transport")
        self.assertEqual(args.arms, ("tmux", "holder"))
        self.assertEqual(args.terminals, {"tmux": TMUX_ID, "holder": GHOSTTY_ID})
        self.assertEqual(args.transports, {"tmux": "tmux", "holder": "holder"})

    def test_engine_mode(self):
        args = probe.parse_args(
            ["--worktree", "w", "--swiftterm-terminal", SWIFTTERM_ID, "--ghostty-terminal", GHOSTTY_ID]
        )
        self.assertEqual(args.mode, "engine")
        self.assertEqual(args.arms, ("swiftterm", "libghostty"))
        self.assertEqual(args.terminals, ENGINE_TERMINALS)
        self.assertEqual(args.transports, {"swiftterm": "holder", "libghostty": "holder"})
        self.assertFalse(args.trust_engines)

    def test_modes_cannot_be_combined(self):
        message = self.parse_error([
            "--worktree", "w", "--tmux-terminal", TMUX_ID,
            "--swiftterm-terminal", SWIFTTERM_ID, "--ghostty-terminal", GHOSTTY_ID,
        ])
        self.assertIn("cannot be combined", message)

    def test_engine_mode_needs_both_arms(self):
        self.assertIn("missing --ghostty-terminal", self.parse_error(["--worktree", "w", "--swiftterm-terminal", SWIFTTERM_ID]))
        self.assertIn("missing --swiftterm-terminal", self.parse_error(["--worktree", "w", "--ghostty-terminal", GHOSTTY_ID]))

    def test_engine_arms_must_be_two_terminals(self):
        message = self.parse_error([
            "--worktree", "w", "--swiftterm-terminal", GHOSTTY_ID.lower(), "--ghostty-terminal", GHOSTTY_ID,
        ])
        self.assertIn("name the same terminal", message)

    def test_engine_flags_are_refused_in_transport_mode(self):
        base = ["--worktree", "w", "--tmux-terminal", TMUX_ID, "--holder-terminal", GHOSTTY_ID]
        self.assertIn("belong to engine mode", self.parse_error(base + ["--trust-engines"]))
        self.assertIn("belong to engine mode", self.parse_error(base + ["--app-pid", "12"]))

    def test_a_mode_is_required(self):
        self.assertIn("transport mode", self.parse_error(["--worktree", "w"]))
        self.assertIn(
            "the following arguments are required: --holder-terminal",
            self.parse_error(["--worktree", "w", "--tmux-terminal", TMUX_ID]),
        )


class VerifyTests(unittest.TestCase):
    ROWS = [
        {"id": SWIFTTERM_ID, "kind": "shell", "transport": "holder"},
        {"id": TMUX_ID, "kind": "shell", "transport": "tmux"},
        {"id": AGENT_ID, "kind": "claude", "transport": "holder"},
    ]

    def test_engine_arm_on_holder_passes(self):
        row = probe.verify(self.ROWS, SWIFTTERM_ID.lower(), "holder", arm="swiftterm")
        self.assertEqual(row["id"], SWIFTTERM_ID)

    def test_engine_arm_on_tmux_is_refused(self):
        with self.assertRaises(SystemExit) as raised:
            probe.verify(self.ROWS, TMUX_ID, "holder", arm="libghostty")
        message = str(raised.exception.code)
        self.assertIn("transport='tmux'", message)
        self.assertIn("libghostty arm", message)
        self.assertIn("both arms on the holder transport", message)

    def test_engine_arm_that_is_an_agent_is_refused(self):
        with self.assertRaises(SystemExit) as raised:
            probe.verify(self.ROWS, AGENT_ID, "holder", arm="swiftterm")
        self.assertIn("not a plain shell", str(raised.exception.code))

    def test_transport_mode_message_is_unchanged(self):
        with self.assertRaises(SystemExit) as raised:
            probe.verify(self.ROWS, TMUX_ID, "holder")
        self.assertEqual(
            raised.exception.code,
            f"terminal {TMUX_ID} is on transport='tmux', but was given as the holder arm."
            " A holder session exists only if the pty-holder flag was on when it spawned.",
        )


class EngineCheckTests(unittest.TestCase):
    def test_standard_setup_confirms_both_arms(self):
        evidence = probe.confirm_engines(ENGINE_TERMINALS, PID, at(-60), FakeLog(STANDARD_ENGINE_LINES))
        self.assertEqual(evidence["swiftterm"].kind, "switch")
        self.assertEqual(evidence["swiftterm"].engine, "swiftterm")
        self.assertEqual(evidence["libghostty"].kind, "active")
        self.assertEqual(evidence["libghostty"].at, at(11))

    def test_ids_match_case_insensitively(self):
        lowered = {arm: terminal.lower() for arm, terminal in ENGINE_TERMINALS.items()}
        evidence = probe.confirm_engines(lowered, PID, at(-60), FakeLog(STANDARD_ENGINE_LINES))
        self.assertEqual(set(evidence), {"swiftterm", "libghostty"})

    def test_swiftterm_arm_still_on_libghostty_is_refused(self):
        message = refusal(self, ENGINE_TERMINALS, FakeLog(STANDARD_ENGINE_LINES[:2]))
        self.assertIn(f"swiftterm arm {SWIFTTERM_ID}", message)
        self.assertIn("puts it on libghostty", message)
        self.assertIn("Nothing has been written to any terminal.", message)
        self.assertNotIn("libghostty arm", message)

    def test_arms_given_the_wrong_way_round_are_both_refused(self):
        swapped = {"swiftterm": GHOSTTY_ID, "libghostty": SWIFTTERM_ID}
        message = refusal(self, swapped, FakeLog(STANDARD_ENGINE_LINES))
        self.assertIn(f"swiftterm arm {GHOSTTY_ID}: its latest engine line", message)
        self.assertIn(f"libghostty arm {SWIFTTERM_ID}: its latest engine line", message)
        self.assertIn("puts it on swiftterm", message)

    def test_a_terminal_no_line_names_is_refused(self):
        message = refusal(self, ENGINE_TERMINALS, FakeLog([active(11, GHOSTTY_ID)]))
        self.assertIn(f"swiftterm arm {SWIFTTERM_ID}: no engine line names it", message)
        self.assertIn("A SwiftTerm build logs nothing", message)

    def test_switch_to_libghostty_needs_an_active_line_after_it(self):
        pending = [active(10, SWIFTTERM_ID), switch(12, SWIFTTERM_ID, "ghostty", "swiftTerm"),
                   switch(20, GHOSTTY_ID, "swiftTerm", "ghostty")]
        message = refusal(self, ENGINE_TERMINALS, FakeLog(pending))
        self.assertIn("is a switch to libghostty with no 'libghostty engine active' line after it", message)
        evidence = probe.confirm_engines(
            ENGINE_TERMINALS, PID, at(-60), FakeLog(pending + [active(21, GHOSTTY_ID)])
        )
        self.assertEqual(evidence["libghostty"].at, at(21))

    def test_fallback_after_the_libghostty_active_line_is_refused(self):
        message = refusal(self, ENGINE_TERMINALS, FakeLog(STANDARD_ENGINE_LINES + [fallback(30)]))
        self.assertIn(f"libghostty arm {GHOSTTY_ID}: a libghostty start fell back", message)
        self.assertNotIn("swiftterm arm", message)

    def test_fallback_before_the_libghostty_active_line_does_not_matter(self):
        lines = [active(10, SWIFTTERM_ID), switch(20, SWIFTTERM_ID, "ghostty", "swiftTerm"),
                 fallback(30), active(40, GHOSTTY_ID)]
        evidence = probe.confirm_engines(ENGINE_TERMINALS, PID, at(-60), FakeLog(lines))
        self.assertEqual(evidence["libghostty"].at, at(40))

    def test_lines_from_another_app_process_are_ignored(self):
        # An earlier app's line about the same id says nothing now: a relaunch
        # rebuilds every panel and forgets every switch.
        stale = STANDARD_ENGINE_LINES + [active(30, SWIFTTERM_ID, pid=PID + 1)]
        probe.confirm_engines(ENGINE_TERMINALS, PID, at(-60), FakeLog(stale))
        only_stale = [active(11, GHOSTTY_ID), switch(20, SWIFTTERM_ID, "ghostty", "swiftTerm", pid=PID + 1)]
        self.assertIn("no engine line names it", refusal(self, ENGINE_TERMINALS, FakeLog(only_stale)))

    def test_switch_skipped_line_is_not_evidence(self):
        # A second press before the rebuild says "stays on ghostty" about a
        # panel that is about to be rebuilt on SwiftTerm.
        skipped = record(
            21,
            f"terminal engine switch skipped terminal={SWIFTTERM_ID}: a switch is already"
            " rebuilding the panel, so the panel stays on ghostty",
            level="Info",
        )
        evidence = probe.confirm_engines(
            ENGINE_TERMINALS, PID, at(-60), FakeLog(STANDARD_ENGINE_LINES + [skipped])
        )
        self.assertEqual(evidence["swiftterm"].kind, "switch")

    def test_an_engine_this_script_does_not_know_is_refused(self):
        lines = [active(10, SWIFTTERM_ID), switch(20, SWIFTTERM_ID, "ghostty", "someEngine"), active(11, GHOSTTY_ID)]
        self.assertIn("an engine this script does not know", refusal(self, ENGINE_TERMINALS, FakeLog(lines)))

    def test_libghostty_arm_needs_info_lines_from_before_its_active_line(self):
        # The heartbeats start after the `active` line: the store may have
        # dropped a switch made between the two.
        log = FakeLog(STANDARD_ENGINE_LINES, lifecycle=heartbeats(600, 900))
        message = refusal(self, ENGINE_TERMINALS, log)
        self.assertIn(f"libghostty arm {GHOSTTY_ID}: the log store holds no .info line", message)
        self.assertNotIn("swiftterm arm", message)
        witness_calls = [call for call in log.calls if call[0] == "lifecycle"]
        self.assertEqual(len(witness_calls), 1)
        self.assertEqual(witness_calls[0][1], at(11) - probe.INFO_WITNESS_WINDOW)

    def test_info_lines_from_another_process_are_no_witness(self):
        message = "heartbeat policy=0 windows=2 active=true keyWindow=true"
        foreign = [record(5, message, level="Info", category="lifecycle", pid=PID + 1)]
        log = FakeLog(STANDARD_ENGINE_LINES, lifecycle=foreign)
        self.assertIn("holds no .info line", refusal(self, ENGINE_TERMINALS, log))

    def test_non_json_and_foreign_lines_are_skipped(self):
        text = "\n".join([
            "Filtering the log data using \"subsystem == ...\"",
            "{not json",
            json.dumps(["a", "list"]),
            record(5, "libghostty engine active for a local PTY"),
            record(6, f"libghostty engine active for {GHOSTTY_ID}", category="terminallatency"),
            *STANDARD_ENGINE_LINES,
        ])
        lines = probe.parse_engine_lines(text, PID)
        self.assertEqual([line.kind for line in lines], ["active", "active", "switch"])

    def test_recheck_passes_when_nothing_changed(self):
        log = FakeLog(STANDARD_ENGINE_LINES)
        before = probe.confirm_engines(ENGINE_TERMINALS, PID, at(-60), log)
        self.assertEqual(probe.recheck_engines(ENGINE_TERMINALS, PID, at(-60), before, log), [])

    def test_recheck_refuses_a_rebuild_during_the_run(self):
        log = FakeLog(STANDARD_ENGINE_LINES)
        before = probe.confirm_engines(ENGINE_TERMINALS, PID, at(-60), log)
        log.engine.append(active(100, GHOSTTY_ID))
        problems = probe.recheck_engines(ENGINE_TERMINALS, PID, at(-60), before, log)
        self.assertEqual(len(problems), 1)
        self.assertIn(f"libghostty arm {GHOSTTY_ID}: a new engine line landed during the run", problems[0])

    def test_recheck_refuses_a_switch_during_the_run(self):
        log = FakeLog(STANDARD_ENGINE_LINES)
        before = probe.confirm_engines(ENGINE_TERMINALS, PID, at(-60), log)
        log.engine.append(switch(100, GHOSTTY_ID, "ghostty", "swiftTerm"))
        problems = probe.recheck_engines(ENGINE_TERMINALS, PID, at(-60), before, log)
        self.assertEqual(len(problems), 1)
        self.assertIn("puts it on swiftterm", problems[0])

    def test_parse_etime(self):
        self.assertEqual(probe.parse_etime("05:07"), 307)
        self.assertEqual(probe.parse_etime(" 01:02:03\n"), 3723)
        self.assertEqual(probe.parse_etime("2-00:00:01"), 172801)
        with self.assertRaises(ValueError):
            probe.parse_etime("")


class RunTests(unittest.TestCase):
    def test_engine_arms_interleave_a_b_b_a(self):
        with tempfile.TemporaryDirectory() as scratch:
            directory = Path(scratch)
            load_map = {arm: {} for arm in probe.ENGINE_ARMS}
            requested = {arm: 0 for arm in probe.ENGINE_ARMS}
            probe.run_samples(directory, ENGINE_TERMINALS, 2, 0.0, load_map, requested, probe.ENGINE_ARMS)
            written = [
                json.loads(path.read_text(encoding="utf-8"))
                for path in sorted(directory.glob("terminal-latency-probe.*.json"))
            ]
        self.assertEqual([request["seq"] for request in written], [1, 2, 3, 4])
        self.assertEqual(
            [request["terminalID"] for request in written],
            [SWIFTTERM_ID, GHOSTTY_ID, GHOSTTY_ID, SWIFTTERM_ID],
        )
        self.assertEqual({arm: sorted(readings) for arm, readings in load_map.items()},
                         {"swiftterm": ["1", "4"], "libghostty": ["2", "3"]})
        self.assertEqual(requested, {"swiftterm": 2, "libghostty": 2})

    def test_echoes_count_by_transport_and_id(self):
        capture = report.parse([
            f"x echo transport=holder terminal={SWIFTTERM_ID} seq=1 ms=1.000",
            f"x echo transport=holder terminal={GHOSTTY_ID.lower()} seq=2 ms=1.000",
            f"x echo transport=holder terminal={AGENT_ID} seq=3 ms=1.000",
            f"x echo transport=tmux terminal={GHOSTTY_ID} seq=4 ms=1.000",
        ])
        transports = {arm: "holder" for arm in probe.ENGINE_ARMS}
        self.assertEqual(
            probe.count_answered(capture, ENGINE_TERMINALS, transports),
            {"swiftterm": 1, "libghostty": 1},
        )

    def test_probe_and_report_agree_on_the_engine_arms(self):
        self.assertEqual(report.ENGINES, probe.ENGINE_ARMS)
        self.assertEqual(report.ENGINE_TRANSPORT, probe.ENGINE_TRANSPORT)
        arms = report.engine_arms(SWIFTTERM_ID, GHOSTTY_ID)
        self.assertEqual([arm.label for arm in arms], list(probe.ENGINE_ARMS))
        self.assertEqual([arm.terminal for arm in arms], [SWIFTTERM_ID, GHOSTTY_ID])


class EngineRunTests(unittest.TestCase):
    """Whole engine-mode runs of `main`, with every outside call replaced."""

    ROWS = [
        {"id": SWIFTTERM_ID, "kind": "shell", "transport": "holder"},
        {"id": GHOSTTY_ID, "kind": "shell", "transport": "holder"},
    ]
    # Two samples per arm, A/B/B/A: seqs 1 and 4 SwiftTerm, 2 and 3 libghostty.
    CAPTURE = "\n".join([
        f"x echo transport=holder terminal={SWIFTTERM_ID} seq=1 ms=2.000",
        f"x echo transport=holder terminal={GHOSTTY_ID} seq=2 ms=1.000",
        f"x echo transport=holder terminal={GHOSTTY_ID} seq=3 ms=1.000",
        f"x echo transport=holder terminal={SWIFTTERM_ID} seq=4 ms=2.000",
    ])
    ARGV = ["--worktree", "w", "--swiftterm-terminal", SWIFTTERM_ID,
            "--ghostty-terminal", GHOSTTY_ID, "--samples", "2", "--gap-ms", "0"]

    def run_main(self, log, argv=None, during_run=None):
        """`main`'s exit status, stdout and stderr, and the request files
        written. `during_run` runs once the samples are written, before the
        capture is read: whatever it changes, the post-run check sees."""
        stdout, stderr = io.StringIO(), io.StringIO()
        written: list[str] = []
        real_run_samples = probe.run_samples

        def run_samples(directory, *args, **kwargs):
            real_run_samples(directory, *args, **kwargs)
            written.extend(sorted(path.name for path in directory.glob("terminal-latency-probe.*")))
            if during_run is not None:
                during_run()

        # The machine's real load would decide the bands. Requests 1 and 2 at
        # idle, 3 and 4 under load: each arm gets one sample in each band.
        loads = iter([1.0, 1.0, 30.0, 30.0])

        with tempfile.TemporaryDirectory() as scratch, contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(probe.os, "getloadavg", lambda: (next(loads), 0.0, 0.0)))
            stack.enter_context(mock.patch.object(probe, "runtime_dir", lambda: Path(scratch)))
            stack.enter_context(mock.patch.object(probe, "terminal_rows", lambda tbd, worktree: self.ROWS))
            stack.enter_context(mock.patch.object(probe, "resolve_app_pid", lambda given: PID))
            stack.enter_context(mock.patch.object(probe, "app_launched_at", lambda pid: at(-60)))
            stack.enter_context(mock.patch.object(probe, "read_app_log", log))
            stack.enter_context(mock.patch.object(probe, "capture_log", lambda since: self.CAPTURE))
            stack.enter_context(mock.patch.object(probe, "run_samples", run_samples))
            stack.enter_context(mock.patch.object(probe.time, "sleep", lambda seconds: None))
            stack.enter_context(contextlib.redirect_stdout(stdout))
            stack.enter_context(contextlib.redirect_stderr(stderr))
            try:
                status = probe.main(argv or self.ARGV)
            except SystemExit as exit_:
                status = exit_.code
        return status, stdout.getvalue(), stderr.getvalue(), written

    def test_confirmed_run_reports_by_engine(self):
        status, out, err, written = self.run_main(FakeLog(STANDARD_ENGINE_LINES))
        self.assertEqual(status, 0, err)
        self.assertEqual(len(written), 4)
        self.assertIn(f"swiftterm arm {SWIFTTERM_ID}: confirmed by", err)
        self.assertIn("terminal engine latency, milliseconds", out)
        self.assertIn(f"arms: swiftterm = {SWIFTTERM_ID[:8]}..", out)
        self.assertIn("swiftterm all          n=2", out)
        self.assertIn("libghostty all         n=2", out)
        self.assertIn("swiftterm flatness     p90 load / p90 idle = 1.00x (WITHIN the 2x bound)", out)
        self.assertIn("libghostty absolute    p90 under load = 1.000 ms (WITHIN the 5 ms bound)", out)
        self.assertIn("echo idle              libghostty 1.000 / swiftterm 2.000 = 0.50x", out)
        self.assertIn("echo load              libghostty 1.000 / swiftterm 2.000 = 0.50x", out)
        self.assertNotIn("NOT VERIFIED", out)

    def test_unconfirmed_engine_refuses_before_any_keystroke(self):
        status, out, err, written = self.run_main(FakeLog(STANDARD_ENGINE_LINES[:2]))
        self.assertIn("REFUSING TO RUN", str(status))
        self.assertIn("puts it on libghostty", str(status))
        self.assertEqual(written, [])
        self.assertEqual(out, "")

    def test_engine_change_during_the_run_refuses_the_report(self):
        log = FakeLog(STANDARD_ENGINE_LINES)
        status, out, err, written = self.run_main(
            log, during_run=lambda: log.engine.append(switch(100, SWIFTTERM_ID, "swiftTerm", "ghostty"))
        )
        self.assertEqual(status, 1)
        self.assertEqual(len(written), 4)
        self.assertIn("REFUSING TO REPORT — an arm's engine line changed during the run", err)
        self.assertIn(f"swiftterm arm {SWIFTTERM_ID}", err)
        self.assertEqual(out, "")

    def test_trust_engines_skips_the_log_and_says_so(self):
        log = FakeLog([])
        status, out, err, written = self.run_main(log, argv=self.ARGV + ["--trust-engines"])
        self.assertEqual(status, 0, err)
        self.assertEqual(log.calls, [])
        self.assertIn("ENGINES NOT VERIFIED", err)
        # Above the figures, so a reader meets it before any number.
        self.assertLess(out.index("ENGINES NOT VERIFIED"), out.index("ECHO"))


if __name__ == "__main__":
    unittest.main()
