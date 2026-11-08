"""Tests for `terminal-latency-probe.py`, the latency run's driver.

They cover the arguments of both modes, the daemon-row refusals, engine
mode's check of each arm's engine against canned `log show --style ndjson`
lines and a canned `defaults read` and `read-type`, the A/B/B/A request order,
the shared `log show` call, and whole runs
of both modes with every outside call replaced. Nothing here reaches `tbd`,
`log`, `defaults`, `pgrep`, `ps` or a running app. Request files go to a temp
directory.

    python3 -I -m unittest discover -s scripts/diag -p 'test_terminal_latency_probe.py'

The report's own fixtures, engine-mode labels and draw bands included, are
its `--self-test`.

The engine lines below are the app's own words. They live in
`TerminalEngineNotice.message`, in
`Sources/TBDApp/Terminal/Engine/TerminalEngineFactory.swift`, and
`Tests/TBDAppTests/TerminalEngineFactoryTests.swift` pins them there. A change
to either side that the other does not follow fails one of the two suites.
"""

from __future__ import annotations

import contextlib
import datetime
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Callable
from unittest import mock

HERE = Path(__file__).resolve().parent


def _load_probe():
    # Registered before `exec_module`, for the reason `load_report_module`
    # gives: a dataclass resolves its module out of `sys.modules`.
    spec = importlib.util.spec_from_file_location(
        "terminal_latency_probe", HERE / "terminal-latency-probe.py"
    )
    assert spec is not None and spec.loader is not None
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
FLAG_ON = probe.EngineFlag("com.github.cheapsteak.tbd", "1", "boolean")


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


def libghostty(when: float, terminal: str, **kwargs) -> str:
    return record(when, f"libghostty engine active for {terminal}", **kwargs)


def swiftterm(when: float, terminal: str, **kwargs) -> str:
    return record(when, f"SwiftTerm engine active for {terminal}", **kwargs)


def fallback(when: float, terminal: str) -> str:
    return record(when, f"libghostty engine unavailable for {terminal}, fell back to SwiftTerm: metalUnavailable")


def flag(when: float, enabled: bool) -> str:
    return record(when, f"libghostty engine experiment turned {'on' if enabled else 'off'}")


# The setup the docstring asks for: the app launched with the engine on, both
# terminals opened on libghostty, then ⌃⌘E in the one that becomes the
# SwiftTerm arm, whose rebuild logs its line.
STANDARD_ENGINE_LINES = [
    flag(1, True),
    libghostty(10, SWIFTTERM_ID),
    libghostty(11, GHOSTTY_ID),
    swiftterm(20, SWIFTTERM_ID),
]


class FakeLog:
    """`read_app_log`'s stand-in: canned ndjson from the asked start on, as
    `log show --start` would give it."""

    def __init__(self, lines: list[str]) -> None:
        self.lines = list(lines)
        self.calls: list[datetime.datetime] = []

    def __call__(self, start):
        self.calls.append(start)
        kept = [
            line for line in self.lines
            if datetime.datetime.strptime(json.loads(line)["timestamp"], "%Y-%m-%d %H:%M:%S.%f%z") >= start
        ]
        return "\n".join(kept) + "\n"


class FakeFlag:
    """`read_engine_flag`'s stand-in: the flag reads `initial` until a test
    changes `self.flag`."""

    def __init__(self, initial=FLAG_ON) -> None:
        self.flag = initial
        self.calls: list[int] = []

    def __call__(self, pid):
        self.calls.append(pid)
        return self.flag


def confirm(lines: list[str], terminals: dict[str, str] = ENGINE_TERMINALS):
    return probe.confirm_engines(terminals, PID, at(-60), FakeLog(lines))


def refusal(test: unittest.TestCase, lines: list[str], terminals: dict[str, str] = ENGINE_TERMINALS) -> str:
    with test.assertRaises(SystemExit) as raised:
        confirm(lines, terminals)
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

    def test_an_equals_form_selects_engine_mode(self):
        args = probe.parse_args(
            ["--worktree", "w", f"--swiftterm-terminal={SWIFTTERM_ID}", "--ghostty-terminal", GHOSTTY_ID]
        )
        self.assertEqual(args.mode, "engine")

    def test_modes_cannot_be_combined(self):
        message = self.parse_error([
            "--worktree", "w", "--tmux-terminal", TMUX_ID,
            "--swiftterm-terminal", SWIFTTERM_ID, "--ghostty-terminal", GHOSTTY_ID,
        ])
        self.assertIn("cannot be combined", message)

    def test_engine_mode_needs_both_arms(self):
        self.assertIn(
            "the following arguments are required: --ghostty-terminal",
            self.parse_error(["--worktree", "w", "--swiftterm-terminal", SWIFTTERM_ID]),
        )
        self.assertIn(
            "the following arguments are required: --swiftterm-terminal",
            self.parse_error(["--worktree", "w", "--ghostty-terminal", GHOSTTY_ID]),
        )

    def test_engine_arms_must_be_two_terminals(self):
        message = self.parse_error([
            "--worktree", "w", "--swiftterm-terminal", GHOSTTY_ID.lower(), "--ghostty-terminal", GHOSTTY_ID,
        ])
        self.assertIn("name the same terminal", message)

    def test_transport_mode_parses_as_it_did_before_engine_mode(self):
        # Both terminal flags are required in the usage, and missing ones get
        # argparse's own words, as before engine mode existed.
        message = self.parse_error(["--worktree", "w"])
        usage = message.split("error:", 1)[0]
        self.assertIn("--tmux-terminal TMUX_TERMINAL", usage)
        self.assertIn("--holder-terminal HOLDER_TERMINAL", usage)
        self.assertNotIn("[--tmux-terminal", usage)
        for absent in ("swiftterm", "ghostty", "trust-engines", "app-pid"):
            self.assertNotIn(absent, usage)
        self.assertIn(
            "error: the following arguments are required: --tmux-terminal, --holder-terminal", message
        )
        self.assertIn(
            "error: the following arguments are required: --holder-terminal",
            self.parse_error(["--worktree", "w", "--tmux-terminal", TMUX_ID]),
        )

    def test_engine_flags_are_unknown_to_transport_mode(self):
        base = ["--worktree", "w", "--tmux-terminal", TMUX_ID, "--holder-terminal", GHOSTTY_ID]
        self.assertIn("unrecognized arguments: --trust-engines", self.parse_error(base + ["--trust-engines"]))
        self.assertIn("unrecognized arguments: --app-pid 12", self.parse_error(base + ["--app-pid", "12"]))


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
        evidence = confirm(STANDARD_ENGINE_LINES)
        self.assertEqual(evidence["swiftterm"].engine, "swiftterm")
        self.assertEqual(evidence["swiftterm"].at, at(20))
        self.assertEqual(evidence["libghostty"].engine, "libghostty")
        self.assertEqual(evidence["libghostty"].at, at(11))

    def test_ids_match_case_insensitively(self):
        lowered = {arm: terminal.lower() for arm, terminal in ENGINE_TERMINALS.items()}
        self.assertEqual(set(confirm(STANDARD_ENGINE_LINES, lowered)), {"swiftterm", "libghostty"})

    def test_swiftterm_arm_still_on_libghostty_is_refused(self):
        message = refusal(self, STANDARD_ENGINE_LINES[:3])
        self.assertIn(f"swiftterm arm {SWIFTTERM_ID}", message)
        self.assertIn("puts it on libghostty", message)
        self.assertIn("Nothing has been written to any terminal.", message)
        self.assertNotIn("libghostty arm", message)

    def test_arms_given_the_wrong_way_round_are_both_refused(self):
        swapped = {"swiftterm": GHOSTTY_ID, "libghostty": SWIFTTERM_ID}
        message = refusal(self, STANDARD_ENGINE_LINES, swapped)
        self.assertIn(f"swiftterm arm {GHOSTTY_ID}: its latest engine line", message)
        self.assertIn(f"libghostty arm {SWIFTTERM_ID}: its latest engine line", message)
        self.assertIn("puts it on swiftterm", message)

    def test_a_terminal_no_line_names_is_refused(self):
        message = refusal(self, [libghostty(11, GHOSTTY_ID)])
        self.assertIn(f"swiftterm arm {SWIFTTERM_ID}: no engine line names it", message)
        self.assertIn("built while the libghostty engine was off logs none", message)
        self.assertNotIn("libghostty arm", message)

    def test_the_latest_line_wins(self):
        # Switched to SwiftTerm and back: libghostty again.
        back = STANDARD_ENGINE_LINES + [swiftterm(30, GHOSTTY_ID), libghostty(40, GHOSTTY_ID)]
        self.assertEqual(confirm(back)["libghostty"].at, at(40))
        # Switched back to libghostty: no longer a SwiftTerm arm.
        self.assertIn("puts it on libghostty", refusal(self, STANDARD_ENGINE_LINES + [libghostty(30, SWIFTTERM_ID)]))

    def test_a_fallback_puts_its_terminal_on_swiftterm(self):
        # Read even without the SwiftTerm line that follows it.
        message = refusal(self, STANDARD_ENGINE_LINES + [fallback(30, GHOSTTY_ID)])
        self.assertIn(f"libghostty arm {GHOSTTY_ID}: its latest engine line", message)
        self.assertIn("puts it on swiftterm", message)
        fell_back = [fallback(15, SWIFTTERM_ID), libghostty(11, GHOSTTY_ID)]
        self.assertEqual(confirm(fell_back)["swiftterm"].at, at(15))

    def test_a_flag_line_after_an_arms_evidence_refuses_it(self):
        # Off and on again after both builds: either arm may have been rebuilt
        # while off, which logs nothing.
        message = refusal(self, STANDARD_ENGINE_LINES + [flag(30, False), flag(31, True)])
        self.assertIn(
            f"swiftterm arm {SWIFTTERM_ID}: \"libghostty engine experiment turned off\"", message
        )
        self.assertIn(f"libghostty arm {GHOSTTY_ID}: \"libghostty engine experiment turned off\"", message)
        self.assertIn("came after its latest engine line", message)
        self.assertIn("until its tab label reads SwiftTerm", message)
        # Between the two builds, it refuses only the arm built before it.
        between = [flag(1, True), libghostty(11, GHOSTTY_ID), flag(15, False), flag(16, True), swiftterm(20, SWIFTTERM_ID)]
        message = refusal(self, between)
        self.assertIn(f"libghostty arm {GHOSTTY_ID}", message)
        self.assertNotIn("swiftterm arm", message)

    def test_a_flag_line_before_every_build_is_no_obstacle(self):
        # The launch line, and a flag turned on before the terminals opened.
        lines = [flag(0, True), flag(2, False), flag(3, True)] + STANDARD_ENGINE_LINES[1:]
        self.assertEqual(confirm(lines)["swiftterm"].at, at(20))

    def test_another_terminals_lines_do_not_matter(self):
        other = "9E9E9E9E-0000-4000-8000-000000000005"
        lines = STANDARD_ENGINE_LINES + [fallback(30, other), swiftterm(31, other)]
        self.assertEqual(confirm(lines)["libghostty"].at, at(11))

    def test_lines_from_another_app_process_are_ignored(self):
        # An earlier app's line about the same id says nothing now: a relaunch
        # rebuilds every panel and forgets every switch.
        confirm(STANDARD_ENGINE_LINES + [libghostty(30, SWIFTTERM_ID, pid=PID + 1)])
        confirm(STANDARD_ENGINE_LINES + [record(30, "libghostty engine experiment turned off", pid=PID + 1)])
        only_stale = [libghostty(11, GHOSTTY_ID), swiftterm(20, SWIFTTERM_ID, pid=PID + 1)]
        self.assertIn("no engine line names it", refusal(self, only_stale))

    def test_switch_lines_are_not_evidence(self):
        # The build that follows a switch logs its own line; the `.info`
        # switch and skip lines are not read.
        lines = STANDARD_ENGINE_LINES + [
            record(30, f"switching terminal engine terminal={GHOSTTY_ID} from=ghostty to=swiftTerm"
                       " override=swiftTerm", level="Info"),
            record(31, f"terminal engine switch skipped terminal={SWIFTTERM_ID}: a switch is"
                       " already rebuilding the panel, so the panel stays on ghostty", level="Info"),
        ]
        evidence = confirm(lines)
        self.assertEqual(evidence["libghostty"].at, at(11))
        self.assertEqual(evidence["swiftterm"].at, at(20))

    def test_non_json_local_pty_and_foreign_lines_are_skipped(self):
        text = "\n".join([
            "Filtering the log data using \"subsystem == ...\"",
            "{not json",
            json.dumps(["a", "list"]),
            record(5, "libghostty engine active for a local PTY"),
            record(6, "SwiftTerm engine active for a local PTY"),
            record(7, "libghostty engine unavailable for a local PTY, fell back to SwiftTerm: x"),
            record(8, f"libghostty engine active for {GHOSTTY_ID}", category="terminallatency"),
            record(9, "libghostty engine experiment turned sideways"),
            *STANDARD_ENGINE_LINES,
        ])
        lines = probe.parse_engine_lines(text, PID)
        self.assertEqual(
            [type(line).__name__ for line in lines], ["FlagLine", "EngineLine", "EngineLine", "EngineLine"]
        )
        self.assertTrue(lines[0].enabled)
        self.assertEqual([line.engine for line in lines[1:]], ["libghostty", "libghostty", "swiftterm"])
        self.assertEqual(lines[3].terminal, SWIFTTERM_ID.lower())

    def recheck_after(self, landed: list[str]) -> list[str]:
        """The post-run check's problems after the standard setup, once
        `landed` has been logged during the run."""
        log = FakeLog(STANDARD_ENGINE_LINES)
        before = probe.confirm_engines(ENGINE_TERMINALS, PID, at(-60), log)
        log.lines.extend(landed)
        return probe.recheck_engines(ENGINE_TERMINALS, PID, at(-60), before, log)

    def test_recheck_passes_when_nothing_changed(self):
        self.assertEqual(self.recheck_after([]), [])

    def test_recheck_refuses_a_rebuild_during_the_run(self):
        problems = self.recheck_after([libghostty(100, GHOSTTY_ID)])
        self.assertEqual(len(problems), 1)
        self.assertIn(f"libghostty arm {GHOSTTY_ID}: a new engine line landed during the run", problems[0])

    def test_recheck_refuses_an_engine_change_during_the_run(self):
        problems = self.recheck_after([swiftterm(100, GHOSTTY_ID)])
        self.assertEqual(len(problems), 1)
        self.assertIn("puts it on swiftterm", problems[0])

    def test_recheck_refuses_a_flag_line_during_the_run(self):
        problems = self.recheck_after([flag(100, False)])
        self.assertEqual(len(problems), 2)
        self.assertTrue(all("turned off" in problem for problem in problems))

    def test_the_log_query_reads_notice_lines_only(self):
        completed = subprocess.CompletedProcess(args=[], returncode=0, stdout="{}\n", stderr="")
        with mock.patch.object(probe.subprocess, "run", return_value=completed) as run:
            self.assertEqual(probe.read_app_log(at(0)), "{}\n")
        command = run.call_args.args[0]
        self.assertEqual(command[:2], ["/usr/bin/log", "show"])
        self.assertNotIn("--info", command)
        self.assertEqual(command[command.index("--style") + 1], "ndjson")
        self.assertIn('category == "terminalEngine"', command[command.index("--predicate") + 1])

    def test_parse_etime(self):
        self.assertEqual(probe.parse_etime("05:07"), 307)
        self.assertEqual(probe.parse_etime(" 01:02:03\n"), 3723)
        self.assertEqual(probe.parse_etime("2-00:00:01"), 172801)
        with self.assertRaises(ValueError):
            probe.parse_etime("")


class LogShowTests(unittest.TestCase):
    """Both `log show` calls, the report's capture and the engine lines, go
    through `log_show`: one command shape and one way to fail."""

    SINCE = datetime.datetime(2026, 11, 8, 10, 0, 0)
    CAPTURE_COMMAND = (
        "/usr/bin/log show --start '2026-11-08 10:00:00' --info --predicate"
        " 'subsystem == \"com.tbd.app\" AND category == \"terminallatency\"'"
    )

    def test_the_capture_reads_info_lines_from_the_run_start(self):
        completed = subprocess.CompletedProcess(args=[], returncode=0, stdout="lines\n", stderr="")
        with mock.patch.object(probe.subprocess, "run", return_value=completed) as run:
            self.assertEqual(probe.capture_log(self.SINCE), "lines\n")
        self.assertEqual(
            run.call_args.args[0],
            [
                "/usr/bin/log", "show", "--start", "2026-11-08 10:00:00", "--info", "--predicate",
                'subsystem == "com.tbd.app" AND category == "terminallatency"',
            ],
        )
        self.assertEqual(run.call_args.kwargs["timeout"], probe.LOG_SHOW_TIMEOUT_SECONDS)

    def failure(self, call: Callable[[datetime.datetime], str], error: Exception) -> str:
        with mock.patch.object(probe.subprocess, "run", side_effect=error), self.assertRaises(SystemExit) as raised:
            call(self.SINCE)
        return str(raised.exception.code)

    def test_a_capture_that_times_out_names_the_command_to_rerun(self):
        message = self.failure(probe.capture_log, subprocess.TimeoutExpired(cmd="log", timeout=120))
        self.assertTrue(message.startswith(
            f"`{self.CAPTURE_COMMAND}` did not return within {probe.LOG_SHOW_TIMEOUT_SECONDS}s,"
            " so this run has no capture to report."
        ), message)
        self.assertIn("re-run that command by hand and pipe it to terminal-latency-report.py.", message)

    def test_both_calls_fail_the_same_way(self):
        timeout = subprocess.TimeoutExpired(cmd="log", timeout=120)
        failed = subprocess.CalledProcessError(64, "log", output="", stderr="log: bad predicate\n")
        for call, consequence in (
            (probe.capture_log, "so this run has no capture to report."),
            (probe.read_app_log, "so no arm's engine could be checked."),
        ):
            for error, how in (
                (timeout, f"did not return within {probe.LOG_SHOW_TIMEOUT_SECONDS}s"),
                (failed, "failed (exit 64: log: bad predicate)"),
            ):
                message = self.failure(call, error)
                self.assertTrue(message.startswith("`/usr/bin/log show --start "), message)
                self.assertIn(f"` {how}, {consequence}", message)


class EngineFlagTests(unittest.TestCase):
    def read(
        self, executable: str, returncode: int, stdout: str = "", stderr: str = "", value_type: str = "boolean"
    ):
        """`read_engine_flag` against a `ps` that finds `executable`, a
        `defaults read` that exits `returncode`, and a `defaults read-type`
        that says `value_type`, and each command it ran."""
        commands: list[list[str]] = []

        def run(command, **kwargs):
            commands.append(command)
            if command[0] == "ps":
                return subprocess.CompletedProcess(command, 0, stdout=executable + "\n", stderr="")
            if command[1] == "read-type":
                return subprocess.CompletedProcess(command, 0, stdout=f"Type is {value_type}\n", stderr="")
            return subprocess.CompletedProcess(command, returncode, stdout=stdout, stderr=stderr)

        with mock.patch.object(probe.subprocess, "run", run):
            return probe.read_engine_flag(PID), commands

    def test_a_bundled_app_reads_its_bundle_domain(self):
        flag, commands = self.read("/Applications/TBD.app/Contents/MacOS/TBDApp", 0, "1\n")
        self.assertEqual(commands[0], ["ps", "-o", "comm=", "-p", str(PID)])
        self.assertEqual(commands[1], ["defaults", "read", "com.github.cheapsteak.tbd", "useGhosttyTerminalEngine"])
        self.assertEqual(commands[2], ["defaults", "read-type", "com.github.cheapsteak.tbd", "useGhosttyTerminalEngine"])
        self.assertEqual(flag, FLAG_ON)
        self.assertIsNone(probe.engine_flag_problem(flag))

    def test_an_unbundled_build_reads_the_tbdapp_domain(self):
        flag, commands = self.read("/Users/someone/tbd/.build/debug/TBDApp", 0, "1\n")
        self.assertEqual(commands[1][2], "TBDApp")
        self.assertTrue(flag.enabled)

    def test_an_unset_key_is_off(self):
        flag, _ = self.read(
            "/Applications/TBD.app/Contents/MacOS/TBDApp", 1,
            stderr="Error: Could not find key 'useGhosttyTerminalEngine' in domain 'com.github.cheapsteak.tbd'.",
        )
        self.assertEqual(flag, probe.EngineFlag("com.github.cheapsteak.tbd", None, None))
        problem = probe.engine_flag_problem(flag)
        assert problem is not None
        self.assertIn(
            "`defaults read com.github.cheapsteak.tbd useGhosttyTerminalEngine` reads nothing (unset, which is off)",
            problem,
        )

    def test_only_a_true_boolean_is_on(self):
        for value, value_type in (
            ("0", "boolean"),
            # `defaults write ... -string 1` prints 1 too, and the app reads it
            # as unset.
            ("1", "string"),
            ("1", "integer"),
            ("true", "string"),
            ("YES", "string"),
            ("", "string"),
        ):
            flag, _ = self.read("/Users/someone/tbd/.build/debug/TBDApp", 0, value + "\n", value_type=value_type)
            self.assertEqual(flag, probe.EngineFlag("TBDApp", value, value_type))
            self.assertFalse(flag.enabled, (value, value_type))
            problem = probe.engine_flag_problem(flag) or ""
            self.assertIn(f"reads {value!r}", problem)
            if value_type != "boolean":
                self.assertIn(
                    f"`defaults read-type TBDApp useGhosttyTerminalEngine` says {value_type}, not boolean", problem
                )
        flag, _ = self.read("/Users/someone/tbd/.build/debug/TBDApp", 0, "1\n", value_type="boolean")
        self.assertTrue(flag.enabled)

    def test_a_process_that_is_gone_is_refused(self):
        def run(command, **kwargs):
            return subprocess.CompletedProcess(command, 1, stdout="", stderr="")

        with mock.patch.object(probe.subprocess, "run", run), self.assertRaises(SystemExit) as raised:
            probe.read_engine_flag(PID)
        self.assertIn(f"process {PID} is not running", str(raised.exception.code))


class RunTests(unittest.TestCase):
    def test_engine_arms_interleave_a_b_b_a(self):
        with tempfile.TemporaryDirectory() as scratch:
            directory = Path(scratch)
            load_map = {arm: {} for arm in probe.ENGINE_ARMS}
            requested = {arm: 0 for arm in probe.ENGINE_ARMS}
            request_times = {arm: {} for arm in probe.ENGINE_ARMS}
            clock = iter([100.0, 101.0, 102.0, 103.0])
            with mock.patch.object(probe.time, "time", lambda: next(clock)):
                probe.run_samples(
                    directory, ENGINE_TERMINALS, 2, 0.0, load_map, requested, probe.ENGINE_ARMS, request_times
                )
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
        self.assertEqual(
            request_times, {"swiftterm": {"1": 100.0, "4": 103.0}, "libghostty": {"2": 101.0, "3": 102.0}}
        )

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


def draw_line(when: datetime.datetime, terminal: str, wait: float) -> str:
    """One draw line as `log show` prints it by default, time first."""
    return (
        f"{when.astimezone().strftime('%Y-%m-%d %H:%M:%S.%f%z')} 0x1  Info 0x0 900 0 TBDApp:"
        f" [com.tbd.app:terminallatency] draw transport=holder terminal={terminal} chunks=1"
        f" oldestms={wait:.3f} newestms={wait:.3f} parsemaxms=0.100 dropped=0 vis=1"
    )


class ReportCommandTests(unittest.TestCase):
    def test_a_kept_engine_map_bands_the_draws_by_its_times(self):
        # A re-report by hand, from the capture and the map the driver kept.
        stamp = datetime.datetime.fromtimestamp
        capture = "\n".join([
            f"x echo transport=holder terminal={SWIFTTERM_ID} seq=1 ms=2.000",
            f"x echo transport=holder terminal={GHOSTTY_ID} seq=2 ms=1.000",
            draw_line(stamp(1000.25 + 0.015), SWIFTTERM_ID, 4.0),
            draw_line(stamp(1000.50 + 0.015), GHOSTTY_ID, 2.0),
        ])
        kept = {
            "swiftterm": {"1": 1.0},
            "libghostty": {"2": 1.0},
            "times": {"swiftterm": {"1": 1000.25}, "libghostty": {"2": 1000.5}},
        }
        stdout = io.StringIO()
        with tempfile.TemporaryDirectory() as scratch:
            capture_path = Path(scratch) / "capture.log"
            capture_path.write_text(capture + "\n", encoding="utf-8")
            map_path = Path(scratch) / "kept.json"
            map_path.write_text(json.dumps(kept), encoding="utf-8")
            argv = [
                "terminal-latency-report.py", str(capture_path),
                "--swiftterm-terminal", SWIFTTERM_ID, "--ghostty-terminal", GHOSTTY_ID,
                "--load-map", str(map_path), "--idle-max", "8",
            ]
            with mock.patch.object(sys, "argv", argv), contextlib.redirect_stdout(stdout):
                # Loaded here, as the driver loads it: `report` takes its
                # default output stream when the module loads.
                status = probe.load_report_module().main()
        out = stdout.getvalue()
        self.assertEqual(status, 0)
        self.assertIn(
            # One sample an arm: banded, with the ratio and no verdict.
            "draw idle              libghostty 2.000 (n=1) / swiftterm 4.000 (n=1) = 0.500x"
            " (too few samples; no verdict)",
            out,
        )
        self.assertIn("swiftterm draw bands   in neither band: 0", out)


class WholeRun:
    """Runs `main` with every outside call replaced, for either mode."""

    def __init__(self, rows: list[dict], capture: str, loads: list[float]) -> None:
        self.rows = rows
        self.capture = capture
        self.loads = loads
        self.clock = 1000.0

    def tick(self) -> float:
        # Each request's wall time, a quarter second apart.
        self.clock += 0.25
        return self.clock

    def run(self, argv, extra_patches=(), during_run=None):
        """`main`'s exit status, stdout and stderr, and the request files
        written. `during_run` runs once the samples are written, before the
        capture is read: whatever it changes, the post-run check sees."""
        stdout, stderr = io.StringIO(), io.StringIO()
        written: list[str] = []
        real_run_samples = probe.run_samples
        loads = iter(self.loads)

        def run_samples(directory, *args, **kwargs):
            real_run_samples(directory, *args, **kwargs)
            written.extend(sorted(path.name for path in directory.glob("terminal-latency-probe.*")))
            if during_run is not None:
                during_run()

        with tempfile.TemporaryDirectory() as scratch, contextlib.ExitStack() as stack:
            # The machine's real load would decide the bands.
            stack.enter_context(mock.patch.object(probe.os, "getloadavg", lambda: (next(loads), 0.0, 0.0)))
            stack.enter_context(mock.patch.object(probe.time, "time", self.tick))
            stack.enter_context(mock.patch.object(probe, "runtime_dir", lambda: Path(scratch)))
            stack.enter_context(mock.patch.object(probe, "terminal_rows", lambda tbd, worktree: self.rows))
            stack.enter_context(mock.patch.object(probe, "capture_log", lambda since: self.capture))
            stack.enter_context(mock.patch.object(probe, "run_samples", run_samples))
            stack.enter_context(mock.patch.object(probe.time, "sleep", lambda seconds: None))
            for target, name, value in extra_patches:
                stack.enter_context(mock.patch.object(target, name, value))
            stack.enter_context(contextlib.redirect_stdout(stdout))
            stack.enter_context(contextlib.redirect_stderr(stderr))
            try:
                status = probe.main(argv)
            except SystemExit as exit_:
                status = exit_.code
        return status, stdout.getvalue(), stderr.getvalue(), written


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

    def run_main(self, log, argv=None, during_run=None, engine_flag=None, capture=CAPTURE):
        # Requests 1 and 2 at idle, 3 and 4 under load: each arm gets one
        # sample in each band.
        whole = WholeRun(self.ROWS, capture, [1.0, 1.0, 30.0, 30.0])
        patches = [
            (probe, "resolve_app_pid", lambda given: PID),
            (probe, "app_launched_at", lambda pid: at(-60)),
            (probe, "read_app_log", log),
            (probe, "read_engine_flag", engine_flag or FakeFlag()),
        ]
        return whole.run(argv or self.ARGV, patches, during_run)

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
        self.assertIn("echo idle              libghostty 1.000 (n=1) / swiftterm 2.000 (n=1) = 0.500x", out)
        self.assertIn("echo load              libghostty 1.000 (n=1) / swiftterm 2.000 (n=1) = 0.500x", out)
        self.assertNotIn("NOT VERIFIED", out)

    def test_draws_are_banded_by_the_request_times_the_run_recorded(self):
        # The run's requests go out at 1000.25 s, 1000.50, 1000.75 and 1001.00,
        # seqs 1 and 2 at idle and 3 and 4 under load. Each draw is logged
        # 10 ms after its request's echo was fed.
        stamp = datetime.datetime.fromtimestamp
        draws = [
            draw_line(stamp(1000.25 + 0.015), SWIFTTERM_ID, 4.0),
            draw_line(stamp(1000.50 + 0.015), GHOSTTY_ID, 2.0),
            draw_line(stamp(1000.75 + 0.015), GHOSTTY_ID, 9.0),
            draw_line(stamp(1001.00 + 0.015), SWIFTTERM_ID, 6.0),
        ]
        with tempfile.TemporaryDirectory() as keep_dir:
            keep = Path(keep_dir) / "kept.json"
            status, out, err, _ = self.run_main(
                FakeLog(STANDARD_ENGINE_LINES),
                argv=self.ARGV + ["--keep-load-map", str(keep)],
                capture="\n".join([self.CAPTURE, *draws]),
            )
            kept = json.loads(keep.read_text(encoding="utf-8"))
        self.assertEqual(status, 0, err)
        self.assertIn("swiftterm draw idle    n=1      p50=   4.000", out)
        self.assertIn("libghostty draw load   n=1      p50=   9.000", out)
        self.assertIn("draw idle              libghostty 2.000 (n=1) / swiftterm 4.000 (n=1) = 0.500x", out)
        self.assertIn("draw load              libghostty 9.000 (n=1) / swiftterm 6.000 (n=1) = 1.500x", out)
        self.assertNotIn("draw on screen         libghostty", out)
        # The kept map carries the times too, so a re-report bands the same way.
        self.assertEqual(kept["times"], {"swiftterm": {"1": 1000.25, "4": 1001.0}, "libghostty": {"2": 1000.5, "3": 1000.75}})
        self.assertEqual(kept["swiftterm"], {"1": 1.0, "4": 30.0})

    def test_unconfirmed_engine_refuses_before_any_keystroke(self):
        status, out, err, written = self.run_main(FakeLog(STANDARD_ENGINE_LINES[:3]))
        self.assertIn("REFUSING TO RUN", str(status))
        self.assertIn("puts it on libghostty", str(status))
        self.assertEqual(written, [])
        self.assertEqual(out, "")

    def test_flag_off_refuses_before_any_keystroke(self):
        engine_flag = FakeFlag(probe.EngineFlag("com.github.cheapsteak.tbd", None, None))
        log = FakeLog(STANDARD_ENGINE_LINES)
        status, out, err, written = self.run_main(log, engine_flag=engine_flag)
        self.assertIn("REFUSING TO RUN — the libghostty engine flag is not on", str(status))
        self.assertIn("Nothing has been written to any terminal.", str(status))
        self.assertEqual(engine_flag.calls, [PID])
        self.assertEqual(written, [])
        self.assertEqual(out, "")

    def test_flag_turned_off_during_the_run_refuses_the_report(self):
        engine_flag = FakeFlag()
        log = FakeLog(STANDARD_ENGINE_LINES)

        def turn_off():
            engine_flag.flag = probe.EngineFlag("com.github.cheapsteak.tbd", "0", "boolean")
            log.lines.append(flag(100, False))

        status, out, err, written = self.run_main(log, during_run=turn_off, engine_flag=engine_flag)
        self.assertEqual(status, 1)
        self.assertEqual(len(written), 4)
        self.assertIn("REFUSING TO REPORT — the engine check no longer holds after the run", err)
        self.assertIn("`defaults read com.github.cheapsteak.tbd useGhosttyTerminalEngine` reads '0'", err)
        self.assertIn("\"libghostty engine experiment turned off\"", err)
        self.assertEqual(out, "")

    def test_engine_change_during_the_run_refuses_the_report(self):
        log = FakeLog(STANDARD_ENGINE_LINES)
        status, out, err, written = self.run_main(
            log, during_run=lambda: log.lines.append(libghostty(100, SWIFTTERM_ID))
        )
        self.assertEqual(status, 1)
        self.assertEqual(len(written), 4)
        self.assertIn("REFUSING TO REPORT — the engine check no longer holds after the run", err)
        self.assertIn(f"swiftterm arm {SWIFTTERM_ID}", err)
        self.assertEqual(out, "")

    def test_trust_engines_skips_the_log_and_says_so(self):
        log = FakeLog([])
        engine_flag = FakeFlag()
        status, out, err, written = self.run_main(
            log, argv=self.ARGV + ["--trust-engines"], engine_flag=engine_flag
        )
        self.assertEqual(status, 0, err)
        self.assertEqual(log.calls, [])
        # The flag is still checked, before the run and after it.
        self.assertEqual(engine_flag.calls, [PID, PID])
        self.assertIn("ENGINES NOT VERIFIED", err)
        # Above the figures, so a reader meets it before any number.
        self.assertLess(out.index("ENGINES NOT VERIFIED"), out.index("ECHO"))

    def test_trust_engines_still_refuses_with_the_flag_off(self):
        engine_flag = FakeFlag(probe.EngineFlag("TBDApp", "0", "boolean"))
        status, out, err, written = self.run_main(
            FakeLog([]), argv=self.ARGV + ["--trust-engines"], engine_flag=engine_flag
        )
        self.assertIn("REFUSING TO RUN — the libghostty engine flag is not on", str(status))
        self.assertEqual(written, [])


class TransportRunTests(unittest.TestCase):
    """Whole transport-mode runs of `main`: the report, a refusal, and no
    engine-mode call."""

    ROWS = [
        {"id": TMUX_ID, "kind": "shell", "transport": "tmux"},
        {"id": GHOSTTY_ID, "kind": "shell", "transport": "holder"},
    ]
    ARGV = ["--worktree", "w", "--tmux-terminal", TMUX_ID, "--holder-terminal", GHOSTTY_ID,
            "--samples", "2", "--gap-ms", "0"]

    @staticmethod
    def forbidden(name: str):
        def call(*args, **kwargs):
            raise AssertionError(f"transport mode called {name}")
        return call

    def run_main(self, capture: str):
        whole = WholeRun(self.ROWS, capture, [1.0, 1.0, 30.0, 30.0])
        patches = [
            (probe, name, self.forbidden(name))
            for name in ("resolve_app_pid", "app_launched_at", "read_app_log", "read_engine_flag")
        ]
        return whole.run(self.ARGV, patches)

    def test_a_complete_run_reports_by_transport(self):
        capture = "\n".join([
            f"x echo transport=tmux terminal={TMUX_ID} seq=1 ms=3.000",
            f"x echo transport=holder terminal={GHOSTTY_ID} seq=2 ms=1.000",
            f"x echo transport=holder terminal={GHOSTTY_ID} seq=3 ms=1.000",
            f"x echo transport=tmux terminal={TMUX_ID} seq=4 ms=3.000",
        ])
        status, out, err, written = self.run_main(capture)
        self.assertEqual(status, 0, err)
        self.assertEqual(len(written), 4)
        self.assertTrue(out.startswith("terminal transport latency, milliseconds\n"), out)
        self.assertIn("(compares transports)", out)
        self.assertIn("tmux all               n=2", out)
        self.assertIn("holder flatness        p90 load / p90 idle = 1.00x (WITHIN the 2x bound)", out)
        for absent in ("ENGINES", "swiftterm", "libghostty", "draw idle"):
            self.assertNotIn(absent, out)

    def test_a_missing_echo_refuses_the_report(self):
        capture = "\n".join([
            f"x echo transport=tmux terminal={TMUX_ID} seq=1 ms=3.000",
            f"x echo transport=holder terminal={GHOSTTY_ID} seq=2 ms=1.000",
            f"x echo transport=tmux terminal={TMUX_ID} seq=4 ms=3.000",
        ])
        status, out, err, _ = self.run_main(capture)
        self.assertEqual(status, 1)
        self.assertIn("REFUSING TO REPORT — an arm's echoes do not match its requests:", err)
        self.assertIn("holder: 1 echoes for 2 requests", err)
        self.assertEqual(out, "")


if __name__ == "__main__":
    unittest.main()
