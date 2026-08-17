"""Tests for scripts/remote_verify.py (stdlib only).

The ticket pool is exercised against real `flock`s in a temp directory, never
the real `~/tbd/runtime`: the pool's whole job is to bound how many remote
runs exist at once, and a mocked lock would prove nothing about that.

One case takes a ticket in a separate process, because a lock that only holds
within one interpreter would bound nothing — forty agent lanes are forty
processes.  That child is killed by the exact pid recorded at spawn; a
pattern kill would match unrelated sessions on this machine.

NOTHING HERE REACHES THE NETWORK. `git` and `gh` are a recorded fake, so the
driver's real ordering — ticket, then push, then dispatch — is asserted from
what it tried to run.  The xUnit fixtures are copied from the two generators
this repo actually meets: SwiftPM's XCTest writer and Swift Testing's own,
whose exact element shapes were read out of the shipped toolchain binaries.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parent.parent
MODULE_PATH = REPO_ROOT / "scripts" / "remote_verify.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("remote_verify", str(MODULE_PATH))
    assert spec is not None and spec.loader is not None, f"no import spec for {MODULE_PATH}"
    module = importlib.util.module_from_spec(spec)
    # Registered before execution, not after: `@dataclass` resolves the
    # annotations of the class it decorates through `sys.modules`, so a module
    # that is not there yet fails to define its own dataclasses.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


remote_verify = _load_module()


# Takes a ticket, announces its index on stdout, and holds it until stdin
# closes.  Run as a separate process so the flock is contended across
# processes rather than within one interpreter.
TICKET_HOLDER = """
import sys
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("remote_verify", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module   # `@dataclass` resolves annotations through it
spec.loader.exec_module(module)

with module.take_dispatch_ticket(Path(sys.argv[2]), int(sys.argv[3])) as index:
    print(index, flush=True)
    sys.stdin.readline()
"""


class DispatchTicketTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.runtime = Path(self.temp.name) / "runtime"

    def tearDown(self):
        self.temp.cleanup()

    def test_tickets_are_bounded_by_the_slot_count(self):
        with remote_verify.take_dispatch_ticket(self.runtime, 2):
            with remote_verify.take_dispatch_ticket(self.runtime, 2):
                with self.assertRaises(remote_verify.NoTicket):
                    with remote_verify.take_dispatch_ticket(self.runtime, 2):
                        pass

    def test_a_released_ticket_is_reusable(self):
        with remote_verify.take_dispatch_ticket(self.runtime, 1):
            pass
        with remote_verify.take_dispatch_ticket(self.runtime, 1) as index:
            self.assertEqual(index, 1)

    def test_a_ticket_is_released_when_the_body_raises(self):
        with contextlib.suppress(RuntimeError):
            with remote_verify.take_dispatch_ticket(self.runtime, 1):
                raise RuntimeError("the remote run blew up")
        with remote_verify.take_dispatch_ticket(self.runtime, 1) as index:
            self.assertEqual(index, 1)

    def test_zero_slots_refuses_immediately(self):
        with self.assertRaises(remote_verify.NoTicket):
            with remote_verify.take_dispatch_ticket(self.runtime, 0):
                pass

    def test_the_ticket_files_are_named_for_their_index(self):
        with remote_verify.take_dispatch_ticket(self.runtime, 2):
            with remote_verify.take_dispatch_ticket(self.runtime, 2):
                pass
        self.assertTrue((self.runtime / "remote-verify-1.lock").exists())
        self.assertTrue((self.runtime / "remote-verify-2.lock").exists())

    def test_a_ticket_held_by_another_process_is_not_reissued(self):
        holder = subprocess.Popen(
            [sys.executable, "-c", TICKET_HOLDER, str(MODULE_PATH), str(self.runtime), "2"],
            text=True,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
        )
        holder_pid = holder.pid
        try:
            assert holder.stdout is not None
            self.assertEqual(holder.stdout.readline().strip(), "1")
            with remote_verify.take_dispatch_ticket(self.runtime, 2) as index:
                self.assertEqual(index, 2, "the other process's ticket was reissued")
            with self.assertRaises(remote_verify.NoTicket):
                with remote_verify.take_dispatch_ticket(self.runtime, 1):
                    self.fail("ticket 1 was issued while another process held it")
        finally:
            with contextlib.suppress(ProcessLookupError):
                os.kill(holder_pid, signal.SIGKILL)
            holder.wait(timeout=10)
            for stream in (holder.stdin, holder.stdout):
                if stream is not None:
                    stream.close()


class SlotCountTests(unittest.TestCase):
    def test_the_default_is_two_slots(self):
        self.assertEqual(remote_verify.configured_slots({}), 2)

    def test_an_empty_setting_takes_the_default(self):
        self.assertEqual(
            remote_verify.configured_slots({"TBD_REMOTE_VERIFY_SLOTS": ""}), 2
        )

    def test_the_setting_overrides_the_default(self):
        self.assertEqual(
            remote_verify.configured_slots({"TBD_REMOTE_VERIFY_SLOTS": "3"}), 3
        )

    def test_an_unreadable_setting_is_rejected_by_name(self):
        with self.assertRaises(ValueError) as caught:
            remote_verify.configured_slots({"TBD_REMOTE_VERIFY_SLOTS": "two"})
        self.assertIn("TBD_REMOTE_VERIFY_SLOTS", str(caught.exception))

    def test_a_negative_setting_is_rejected_by_name(self):
        with self.assertRaises(ValueError) as caught:
            remote_verify.configured_slots({"TBD_REMOTE_VERIFY_SLOTS": "-1"})
        self.assertIn("TBD_REMOTE_VERIFY_SLOTS", str(caught.exception))


class BoundedCommandTests(unittest.TestCase):
    """Every subprocess is bounded, and none of them raise.

    A `gh` that never returns is the failure that matters: the bounded waits
    only test their deadline between calls, so one hung call would hold a
    dispatch ticket past every timeout in the module — and with two tickets,
    two of them wedge the valve for the whole fleet.
    """

    def test_a_command_that_overruns_is_reported_rather_than_awaited(self):
        run = remote_verify.system_runner(Path.cwd(), timeout=0.05)
        result = run([sys.executable, "-c", "import time; time.sleep(30)"])
        self.assertNotEqual(result.status, 0, "a hung command was reported as success")
        self.assertEqual(result.status, remote_verify.STATUS_TIMED_OUT)
        self.assertIn("did not answer within", result.stderr)

    def test_a_command_that_cannot_start_is_a_status_not_an_exception(self):
        run = remote_verify.system_runner(Path.cwd(), timeout=5.0)
        result = run(["./definitely-not-a-program-remote-verify"])
        self.assertEqual(result.status, remote_verify.STATUS_NOT_RUNNABLE)
        self.assertIn("could not run", result.stderr)

    def test_an_ordinary_command_still_returns_its_output(self):
        run = remote_verify.system_runner(Path.cwd(), timeout=30.0)
        result = run([sys.executable, "-c", "print('hello')"])
        self.assertEqual(result.status, 0)
        self.assertEqual(result.stdout.strip(), "hello")

    def test_a_hung_gh_ends_the_wait_instead_of_holding_the_ticket(self):
        # The bound composes with the deadline: a call that answers "timed out"
        # is a failed call, and a failed `gh run list` is already a refusal.
        runner = RecordingRunner().reply(
            "gh", "run", "list",
            status=remote_verify.STATUS_TIMED_OUT,
            stderr="gh did not answer within 300s",
        )
        with self.assertRaises(remote_verify.Refused) as caught:
            remote_verify.await_dispatched_run(
                runner, "c0ffee", timeout=30.0, poll=5.0,
                requester_alive=lambda: True,
                sleep=lambda _: None, monotonic=lambda: 0.0,
                report=lambda *_: None,
            )
        self.assertIn("did not answer", str(caught.exception))


class RequesterLivenessTests(unittest.TestCase):
    """A verdict nobody is waiting for is not worth a dispatch ticket.

    The chain is test.sh -> remote-verify.sh -> `exec python3`, so a killed
    agent session kills a shell several steps up and never moves this process's
    own ppid. Both readings are needed, and neither covers the other.
    """

    def test_a_live_requester_keeps_the_run_going(self):
        alive = remote_verify.requester_watch({})
        self.assertTrue(alive(), "this test's own parent is running")

    def test_a_dead_ancestor_ends_the_watch(self):
        holder = subprocess.Popen(
            [sys.executable, "-c", "import sys; sys.stdin.readline()"],
            text=True,
            stdin=subprocess.PIPE,
        )
        holder_pid = holder.pid
        try:
            alive = remote_verify.requester_watch({}, ancestors=(holder_pid,))
            self.assertTrue(alive())
            # Killed by the exact pid recorded at spawn; a pattern kill would
            # match unrelated sessions on this machine.
            os.kill(holder_pid, signal.SIGKILL)
            holder.wait(timeout=10)
            self.assertFalse(alive(), "a dead ancestor was read as alive")
        finally:
            with contextlib.suppress(ProcessLookupError):
                os.kill(holder_pid, signal.SIGKILL)
            holder.wait(timeout=10)
            if holder.stdin is not None:
                holder.stdin.close()

    def test_a_reparented_process_ends_the_watch(self):
        parent = os.getppid()
        alive = remote_verify.requester_watch({}, getppid=lambda: parent, ancestors=())
        self.assertTrue(alive())
        moved = remote_verify.requester_watch(
            {}, getppid=iter([parent, parent + 1]).__next__, ancestors=()
        )
        self.assertFalse(moved(), "a reparent was not noticed")

    def test_the_escape_hatch_disarms_the_watch(self):
        alive = remote_verify.requester_watch(
            {remote_verify.ALLOW_ORPHAN_SETTING: "1"},
            getppid=lambda: 999999,
            ancestors=(999999,),
        )
        self.assertTrue(alive(), "a deliberately detached run was abandoned")

    # The clock advances so that a wait which stopped watching the requester
    # ends on its own deadline instead of spinning: the assertion has to be
    # `Abandoned` specifically, not merely "something was raised eventually".
    def test_a_dead_requester_ends_the_correlation_wait(self):
        clock = FakeClock()
        runner = RecordingRunner().reply("gh", "run", "list", stdout="[]")
        with self.assertRaises(remote_verify.Abandoned) as caught:
            remote_verify.await_dispatched_run(
                runner, "c0ffee", timeout=30.0, poll=5.0,
                requester_alive=lambda: False,
                sleep=clock.sleep, monotonic=clock.monotonic,
                report=lambda *_: None,
            )
        self.assertIn("exited", str(caught.exception))
        self.assertEqual(runner.ran("gh", "run", "list"), [], "GitHub was asked anyway")

    def test_a_dead_requester_ends_the_completion_wait(self):
        clock = FakeClock()
        runner = RecordingRunner().reply(
            "gh", "run", "view", stdout=json.dumps({"status": "in_progress"})
        )
        with self.assertRaises(remote_verify.Abandoned):
            remote_verify.await_completion(
                runner, "4242", timeout=30.0, poll=5.0,
                requester_alive=lambda: False,
                sleep=clock.sleep, monotonic=clock.monotonic,
                report=lambda *_: None,
            )


# --- fixtures ----------------------------------------------------------------

# SwiftPM's XCTest xUnit writer: one flat `<testsuites>`, unindented, with the
# failure message on the attribute `--experimental-xunit-message-failure` fills.
XCTEST_STYLE = """<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
<testsuite name="TestResults" errors="0" tests="3" failures="1" time="12.5">
<testcase classname="TBDDaemonTests.OrphanGCTests" name="reclaimsStaleWorktrees" time="0.031"/>
<testcase classname="TBDDaemonTests.OrphanGCTests" name="quarantinesProfileDirs" time="0.044"><failure message="XCTAssertEqual failed: (&quot;1&quot;) is not equal to (&quot;2&quot;)"></failure></testcase>
</testsuite>
</testsuites>
"""

# Swift Testing's own writer: the same elements, indented, and with `<skipped />`
# for a disabled test.
SWIFT_TESTING_STYLE = """<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="TestResults" errors="0" tests="4" failures="2" time="8.250">
    <testcase classname="TBDAppTests" name="valveRoutesRemote()" time="0.100"><failure message="Expectation failed: (actual → 1) == (expected → 2)" /></testcase>
    <testcase classname="TBDAppTests" name="skippedForNow()" time="0.000"><skipped /></testcase>
    <testcase classname="TBDAppTests" name="rendersFailures()" time="0.010" />
    <testcase classname="TBDAppTests" name="pushesAfterTheTicket()" time="0.200"><failure message="Expectation failed: ticket was not held" /></testcase>
  </testsuite>
</testsuites>
"""

CLEAN_STYLE = """<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="TestResults" errors="0" tests="2" failures="0" time="1.5">
    <testcase classname="TBDDaemonLiveTests" name="attachesToTmux()" time="1.400" />
  </testsuite>
</testsuites>
"""

# A run killed mid-write leaves exactly this: a prefix with no closing tag.
TRUNCATED = """<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="TestResults" errors="0" tests="9" failures="1" time="3.0">
    <testcase classname="TBDDaemonTests" name="died"""


def write_results(directory: Path, **files: str) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    for name, body in files.items():
        (directory / f"{name}.xml").write_text(body, encoding="utf-8")
    return directory


def completed(status: int = 0, stdout: str = "", stderr: str = ""):
    return remote_verify.Completed(status, stdout, stderr)


class RecordingRunner:
    """A `git`/`gh` stand-in that records every argv and replies from a script.

    Replies match on an argv prefix, so each case scripts only the calls it
    cares about and everything else succeeds silently.  The recording is the
    point: the driver's ordering guarantee — no push before a ticket, no
    dispatch before a push — is only observable from what it tried to run.
    """

    def __init__(self):
        self.calls: list[list[str]] = []
        self.replies: list[tuple[tuple[str, ...], object]] = []

    def reply(self, *prefix: str, handler=None, status: int = 0, stdout: str = "", stderr: str = ""):
        self.replies.append(
            (tuple(prefix), handler or (lambda argv: completed(status, stdout, stderr)))
        )
        return self

    def __call__(self, argv):
        argv = list(argv)
        self.calls.append(argv)
        for prefix, handler in self.replies:
            if tuple(argv[: len(prefix)]) == prefix:
                return handler(argv)
        return completed()

    def ran(self, *prefix: str) -> list[list[str]]:
        return [call for call in self.calls if tuple(call[: len(prefix)]) == prefix]


class FakeClock:
    """Monotonic time the test advances, so no case waits on a wall clock."""

    def __init__(self):
        self.now = 0.0

    def monotonic(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds if seconds > 0 else 1.0


def run_json(**overrides):
    run = {
        "databaseId": 4242,
        "headSha": "c0ffee",
        "status": "completed",
        "conclusion": "success",
        "event": "workflow_dispatch",
        "url": "https://example.invalid/runs/4242",
    }
    run.update(overrides)
    return run


class RenderingTests(unittest.TestCase):
    """The artifact holds one file per pass, and a red run may publish fewer."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.dir = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def render(self, **files):
        write_results(self.dir, **files)
        return remote_verify.render_results(remote_verify.result_files(self.dir))

    def test_failures_from_every_result_file_are_merged(self):
        report = self.render(
            **{
                "xunit-daemon": XCTEST_STYLE,
                "xunit-app": SWIFT_TESTING_STYLE,
                "xunit-quiet": CLEAN_STYLE,
            }
        )
        self.assertEqual(report.total, 3, report.lines)
        rendered = "\n".join(report.lines)
        self.assertIn("3 result file(s)", rendered)
        self.assertIn(
            "TBDDaemonTests.OrphanGCTests.quarantinesProfileDirs: "
            'XCTAssertEqual failed: ("1") is not equal to ("2")',
            rendered,
        )
        self.assertIn(
            "TBDAppTests.valveRoutesRemote(): "
            "Expectation failed: (actual → 1) == (expected → 2)",
            rendered,
        )
        self.assertIn("TBDAppTests.pushesAfterTheTicket()", rendered)
        self.assertIn("xunit-daemon.xml", rendered)
        self.assertIn("xunit-app.xml", rendered)
        # The clean pass contributes nothing to read past.
        self.assertNotIn("xunit-quiet.xml", rendered)

    def test_a_result_file_that_never_arrived_is_not_an_error(self):
        report = self.render(**{"xunit-daemon": XCTEST_STYLE})
        self.assertEqual(report.total, 1)
        self.assertEqual(report.unreadable, ())
        self.assertIn("1 result file(s)", "\n".join(report.lines))

    def test_an_unreadable_file_does_not_hide_the_others(self):
        report = self.render(
            **{"xunit-app": SWIFT_TESTING_STYLE, "xunit-quiet": TRUNCATED}
        )
        self.assertEqual(report.total, 2, report.lines)
        self.assertEqual(report.unreadable, ("xunit-quiet.xml",))
        rendered = "\n".join(report.lines)
        self.assertIn("xunit-quiet.xml — unreadable", rendered)
        self.assertIn("TBDAppTests.valveRoutesRemote()", rendered)

    def test_an_empty_file_is_reported_rather_than_swallowed(self):
        report = self.render(**{"xunit-daemon": ""})
        self.assertEqual(report.total, 0)
        self.assertEqual(report.unreadable, ("xunit-daemon.xml",))

    def test_a_red_run_with_no_failures_says_where_to_look(self):
        report = self.render(**{"xunit-quiet": CLEAN_STYLE})
        self.assertEqual(report.total, 0)
        self.assertIn("outside the test passes", "\n".join(report.lines))

    def test_no_results_at_all_still_produces_a_line(self):
        report = remote_verify.render_results([])
        self.assertEqual(report.total, 0)
        self.assertTrue(report.lines)

    def test_skipped_and_passing_cases_are_not_failures(self):
        failures = remote_verify.failures_in(
            write_results(self.dir, only=SWIFT_TESTING_STYLE) / "only.xml"
        )
        names = [failure.name for failure in failures]
        self.assertNotIn("skippedForNow()", names)
        self.assertNotIn("rendersFailures()", names)

    def test_a_missing_message_is_named_rather_than_blank(self):
        body = (
            '<testsuites><testsuite name="TestResults">'
            '<testcase classname="A" name="b"><failure/></testcase>'
            "</testsuite></testsuites>"
        )
        report = self.render(**{"xunit-daemon": body})
        self.assertIn("A.b: (no message)", "\n".join(report.lines))

    def test_a_message_carried_as_element_text_is_used(self):
        body = (
            '<testsuites><testsuite name="TestResults">'
            '<testcase classname="A" name="b"><failure>died in the fixture</failure></testcase>'
            "</testsuite></testsuites>"
        )
        report = self.render(**{"xunit-daemon": body})
        self.assertIn("A.b: died in the fixture", "\n".join(report.lines))

    def test_an_error_element_counts_as_a_failure(self):
        body = (
            '<testsuites><testsuite name="TestResults">'
            '<testcase classname="A" name="b"><error message="crashed"/></testcase>'
            "</testsuite></testsuites>"
        )
        report = self.render(**{"xunit-daemon": body})
        self.assertEqual(report.total, 1)
        self.assertIn("A.b: crashed", "\n".join(report.lines))

    def test_a_missing_classname_falls_back_to_the_file(self):
        body = (
            '<testsuites><testsuite name="TestResults">'
            '<testcase name="b"><failure message="x"/></testcase>'
            "</testsuite></testsuites>"
        )
        report = self.render(**{"xunit-daemon": body})
        self.assertIn("xunit-daemon.b: x", "\n".join(report.lines))

    def test_duplicate_failures_within_a_file_collapse(self):
        case = '<testcase classname="A" name="b"><failure message="x"/></testcase>'
        body = f'<testsuites><testsuite name="TestResults">{case}{case}</testsuite></testsuites>'
        report = self.render(**{"xunit-daemon": body})
        self.assertEqual(report.total, 1)

    def test_the_render_is_bounded_and_says_what_it_withheld(self):
        cases = "".join(
            f'<testcase classname="A" name="test{index}"><failure message="x"/></testcase>'
            for index in range(60)
        )
        report = self.render(
            **{"xunit-daemon": f'<testsuites><testsuite name="TestResults">{cases}</testsuite></testsuites>'}
        )
        self.assertEqual(report.total, 60)
        rendered = "\n".join(report.lines)
        self.assertEqual(rendered.count("A.test"), 50, "the render was not bounded")
        self.assertIn("and 10 more failing tests", rendered)

    def test_result_files_finds_nested_xml_and_nothing_else(self):
        write_results(self.dir / "xunit-results", **{"xunit-app": SWIFT_TESTING_STYLE})
        (self.dir / "notes.txt").write_text("not results", encoding="utf-8")
        found = remote_verify.result_files(self.dir)
        self.assertEqual([path.name for path in found], ["xunit-app.xml"])


class RunSelectionTests(unittest.TestCase):
    def test_the_dispatched_run_for_this_sha_is_chosen(self):
        runs = [
            run_json(databaseId=1, headSha="other"),
            run_json(databaseId=2, headSha="c0ffee"),
        ]
        chosen = remote_verify.select_run(runs, "c0ffee")
        self.assertEqual(chosen["databaseId"], 2)

    def test_the_newest_matching_run_wins(self):
        runs = [run_json(databaseId=9), run_json(databaseId=8)]
        self.assertEqual(remote_verify.select_run(runs, "c0ffee")["databaseId"], 9)

    def test_a_pull_request_run_for_the_same_sha_is_ignored(self):
        runs = [run_json(databaseId=3, event="pull_request")]
        self.assertIsNone(remote_verify.select_run(runs, "c0ffee"))

    def test_a_boolean_run_id_is_refused_rather_than_coerced(self):
        # `isinstance(True, int)` is True in python, so an unguarded read would
        # address run 1 — a real, unrelated run.
        runs = [run_json(databaseId=True)]
        self.assertIsNone(remote_verify.select_run(runs, "c0ffee"))

    def test_nothing_matching_yields_nothing(self):
        self.assertIsNone(remote_verify.select_run([], "c0ffee"))

    def test_a_run_that_predates_the_dispatch_is_skipped(self):
        runs = [run_json(databaseId=1000), run_json(databaseId=1001)]
        chosen = remote_verify.select_run(runs, "c0ffee", exclude=frozenset({1000}))
        self.assertEqual(chosen["databaseId"], 1001)

    def test_every_run_being_stale_yields_nothing_rather_than_the_newest(self):
        runs = [run_json(databaseId=1000), run_json(databaseId=999)]
        self.assertIsNone(
            remote_verify.select_run(runs, "c0ffee", exclude=frozenset({999, 1000}))
        )


class VerdictTests(unittest.TestCase):
    def test_success_is_a_pass(self):
        self.assertEqual(remote_verify.verdict_for("success"), 0)

    def test_failure_is_a_fail(self):
        self.assertEqual(remote_verify.verdict_for("failure"), 1)

    def test_anything_else_is_no_verdict(self):
        for conclusion in ("cancelled", "skipped", "timed_out", "startup_failure", None):
            self.assertIsNone(
                remote_verify.verdict_for(conclusion),
                f"{conclusion!r} was read as a verdict",
            )


class CorrelationTests(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()

    def wait(self, runner, *, timeout=30.0, exclude=frozenset()):
        return remote_verify.await_dispatched_run(
            runner, "c0ffee",
            timeout=timeout, poll=5.0,
            requester_alive=lambda: True, exclude=exclude,
            sleep=self.clock.sleep, monotonic=self.clock.monotonic,
            report=lambda *_: None,
        )

    def test_a_run_that_registers_late_is_still_found(self):
        answers = ["[]", "[]", json.dumps([run_json()])]
        runner = RecordingRunner().reply(
            "gh", "run", "list", handler=lambda argv: completed(stdout=answers.pop(0))
        )
        self.assertEqual(self.wait(runner)["databaseId"], 4242)

    def test_a_run_that_never_registers_refuses_by_name(self):
        runner = RecordingRunner().reply("gh", "run", "list", stdout="[]")
        with self.assertRaises(remote_verify.Refused) as caught:
            self.wait(runner, timeout=10.0)
        self.assertIn("c0ffee", str(caught.exception))

    def test_a_failed_query_refuses_rather_than_reading_nothing(self):
        runner = RecordingRunner().reply(
            "gh", "run", "list", status=1, stderr="API rate limit exceeded"
        )
        with self.assertRaises(remote_verify.Refused) as caught:
            self.wait(runner)
        self.assertIn("rate limit", str(caught.exception))

    def test_unreadable_json_refuses(self):
        runner = RecordingRunner().reply("gh", "run", "list", stdout="not json at all")
        with self.assertRaises(remote_verify.Refused):
            self.wait(runner)

    def test_completion_is_waited_for(self):
        answers = [
            json.dumps({"status": "queued"}),
            json.dumps({"status": "in_progress"}),
            json.dumps({"status": "completed", "conclusion": "failure"}),
        ]
        runner = RecordingRunner().reply(
            "gh", "run", "view", handler=lambda argv: completed(stdout=answers.pop(0))
        )
        finished = remote_verify.await_completion(
            runner, "4242", timeout=600.0, poll=10.0,
            requester_alive=lambda: True,
            sleep=self.clock.sleep, monotonic=self.clock.monotonic,
            report=lambda *_: None,
        )
        self.assertEqual(finished["conclusion"], "failure")

    def test_a_run_that_never_completes_refuses_by_name(self):
        runner = RecordingRunner().reply(
            "gh", "run", "view", stdout=json.dumps({"status": "in_progress"})
        )
        with self.assertRaises(remote_verify.Refused) as caught:
            remote_verify.await_completion(
                runner, "4242", timeout=60.0, poll=10.0,
                requester_alive=lambda: True,
                sleep=self.clock.sleep, monotonic=self.clock.monotonic,
                report=lambda *_: None,
            )
        self.assertIn("4242", str(caught.exception))

    def test_a_run_dispatched_before_this_lane_is_not_adopted(self):
        # THE STALE-RUN TRAP. `gh run list` answers instantly with the older
        # dispatch of the same commit and only registers the new one seconds
        # later, so an unfiltered first poll adopts the wrong run every time —
        # reporting its verdict while the run this lane paid for burns a macOS
        # slot unwatched.
        stale = run_json(databaseId=1000, conclusion="failure")
        fresh = run_json(databaseId=1001, conclusion="success")
        answers = [
            json.dumps([stale]),
            json.dumps([stale]),
            json.dumps([fresh, stale]),
        ]
        runner = RecordingRunner().reply(
            "gh", "run", "list", handler=lambda argv: completed(stdout=answers.pop(0))
        )
        chosen = self.wait(runner, exclude=frozenset({1000}))
        self.assertEqual(chosen["databaseId"], 1001, "a stale run was adopted")

    def test_the_baseline_names_only_dispatched_runs_for_this_sha(self):
        runner = RecordingRunner().reply(
            "gh", "run", "list",
            stdout=json.dumps(
                [
                    run_json(databaseId=1),
                    run_json(databaseId=2, headSha="other"),
                    run_json(databaseId=3, event="pull_request"),
                    run_json(databaseId=True),
                ]
            ),
        )
        self.assertEqual(
            remote_verify.baseline_run_ids(runner, "c0ffee"), frozenset({1})
        )


class FailedJobTests(unittest.TestCase):
    def test_the_red_jobs_are_named(self):
        run = {
            "jobs": [
                {"name": "Lint", "conclusion": "failure"},
                {"name": "Test", "conclusion": "success"},
                {"name": "Live", "conclusion": "cancelled"},
            ]
        }
        self.assertEqual(remote_verify.failed_job_names(run), ["Lint", "Live"])

    def test_a_run_without_jobs_names_none(self):
        self.assertEqual(remote_verify.failed_job_names({}), [])


class DriverTests(unittest.TestCase):
    """The ordering guarantee, and the verdict, end to end without a network."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.runtime = self.root / "runtime"
        self.clock = FakeClock()
        self.printed: list[str] = []
        self.reported: list[str] = []

    def tearDown(self):
        self.temp.cleanup()

    def drive(self, runner, *, slots=2, ref="preflight/tbd/lane", sha="c0ffee", alive=None):
        return remote_verify.drive(
            ref=ref, sha=sha,
            runtime_dir=self.runtime, slots=slots,
            run_command=runner,
            poll=5.0, correlate_timeout=60.0, run_timeout=600.0,
            requester_alive=alive or (lambda: True),
            sleep=self.clock.sleep, monotonic=self.clock.monotonic,
            report=self.reported.append, write=self.printed.append,
        )

    def output(self) -> str:
        return "\n".join(self.printed)

    def diagnostics(self) -> str:
        return "\n".join(self.reported)

    def results_runner(self, conclusion, **files):
        """A `gh` whose run reaches `conclusion` and publishes `files`.

        Both verdicts download the artifact: a red run needs the failures, and
        a green one needs the population, because a caller reading `Test run
        with N tests` cannot be handed a number no result file supports.
        """

        def download(argv):
            if not files:
                return completed(1, stderr="no artifact matches xunit-results")
            destination = Path(argv[argv.index("--dir") + 1])
            write_results(destination, **files)
            return completed()

        # The first listing is the baseline, taken before the dispatch, and a
        # commit nobody has dispatched yet has no run — which is what makes the
        # run that appears afterwards identifiable as this lane's.
        listed = json.dumps([run_json(conclusion=conclusion)])
        answers = ["[]"]

        def run_list(argv):
            return completed(stdout=answers.pop(0) if answers else listed)

        return (
            RecordingRunner()
            .reply("gh", "run", "list", handler=run_list)
            .reply(
                "gh", "run", "view",
                stdout=json.dumps(
                    {
                        "status": "completed",
                        "conclusion": conclusion,
                        "url": "https://example.invalid/runs/4242",
                        "jobs": [{"name": "Test", "conclusion": conclusion}],
                    }
                ),
            )
            .reply("gh", "run", "download", handler=download)
        )

    def passing_runner(self, **files):
        return self.results_runner("success", **(files or {"xunit-quiet": CLEAN_STYLE}))

    def passing_runner_without_results(self):
        """A green run whose artifact never arrived — nothing to count."""
        return self.results_runner("success")

    def failing_runner(self, **files):
        return self.results_runner("failure", **files)

    def test_a_passing_run_exits_zero(self):
        runner = self.passing_runner()
        self.assertEqual(self.drive(runner), 0)
        self.assertIn("passed", self.output())

    def test_a_passing_run_states_the_population_it_executed(self):
        # SIX CALL SITES GREP FOR THIS EXACT LINE — `scripts/git-hooks/pre-push`,
        # `scripts/nightly-flake-stress.sh` and three steps of `test.yml` — and
        # read its absence as a collapsed or truncated suite. Without it a GREEN
        # remote verdict blocks the push naming the wrong cause.
        runner = self.passing_runner(
            **{"xunit-daemon": XCTEST_STYLE, "xunit-app": SWIFT_TESTING_STYLE, "xunit-quiet": CLEAN_STYLE}
        )
        self.assertEqual(self.drive(runner), 0)
        matched = re.search(r"Test run with (\d+) tests?", self.output())
        self.assertIsNotNone(matched, f"no summary line in {self.output()!r}")
        # 3 + 4 + 2, summed across the passes exactly as the files declare them.
        self.assertEqual(matched.group(1), "9")

    def test_a_single_test_is_named_in_the_singular(self):
        one = (
            '<testsuites><testsuite name="TestResults" tests="1">'
            '<testcase classname="A" name="b"/></testsuite></testsuites>'
        )
        self.assertEqual(self.drive(self.passing_runner(**{"xunit-one": one})), 0)
        self.assertIn("Test run with 1 test passed", self.output())

    def test_a_pass_whose_results_are_missing_refuses_rather_than_inventing(self):
        # A count nobody can support is worse than no verdict: it would be read
        # as the run's real population by every floor check downstream.
        runner = self.passing_runner_without_results()
        self.assertEqual(self.drive(runner), 78)
        self.assertNotIn("Test run with", self.output())
        # Named, not merely refused: a refusal that says something else is a
        # refusal for a different reason, and this one has to be readable.
        self.assertIn("could not be counted", self.diagnostics())

    def test_a_pass_whose_results_are_unreadable_refuses(self):
        runner = self.passing_runner(**{"xunit-daemon": TRUNCATED})
        self.assertEqual(self.drive(runner), 78)
        self.assertNotIn("Test run with", self.output())
        self.assertIn("could not be counted", self.diagnostics())

    def test_a_pass_whose_results_declare_no_population_refuses(self):
        # Readable, well-formed, and silent about how many tests ran: there is
        # no number to state, so there is no verdict to report.
        body = (
            '<testsuites><testsuite name="TestResults">'
            '<testcase classname="A" name="b"/></testsuite></testsuites>'
        )
        self.assertEqual(self.drive(self.passing_runner(**{"xunit-daemon": body})), 78)
        self.assertNotIn("Test run with", self.output())
        self.assertIn("could not be counted", self.diagnostics())

    def test_a_failing_run_renders_the_failing_tests(self):
        runner = self.failing_runner(
            **{
                "xunit-daemon": XCTEST_STYLE,
                "xunit-app": SWIFT_TESTING_STYLE,
                "xunit-quiet": CLEAN_STYLE,
            }
        )
        self.assertEqual(self.drive(runner), 1)
        rendered = self.output()
        self.assertIn("FAILED", rendered)
        self.assertIn("failing jobs: Test", rendered)
        self.assertIn("TBDDaemonTests.OrphanGCTests.quarantinesProfileDirs", rendered)
        self.assertIn("TBDAppTests.valveRoutesRemote()", rendered)
        self.assertIn("Test run with 9 tests failed", rendered)

    def test_a_failing_run_with_no_artifact_still_fails_loudly(self):
        # An uncountable red run is still red: the verdict came from the run's
        # conclusion, and only the pass path needs a population it can state.
        runner = self.failing_runner()
        self.assertEqual(self.drive(runner), 1)
        self.assertIn("could not download", self.output())
        self.assertIn("https://example.invalid/runs/4242", self.output())
        self.assertNotIn("Test run with", self.output())

    def test_no_ticket_refuses_without_pushing_or_dispatching(self):
        # The ordering guarantee: a lane that never got a ticket must leave no
        # ref behind and must not have spent a dispatch.
        runner = self.passing_runner()
        self.assertEqual(self.drive(runner, slots=0), 78)
        self.assertEqual(runner.ran("git", "push"), [])
        self.assertEqual(runner.ran("gh", "workflow", "run"), [])

    def test_the_ticket_is_taken_before_the_push(self):
        held = []

        def push(argv):
            held.append(sorted(path.name for path in self.runtime.glob("*.lock")))
            return completed()

        runner = self.passing_runner().reply("git", "push", handler=push)
        self.assertEqual(self.drive(runner), 0)
        self.assertEqual(held, [["remote-verify-1.lock"]])

    def test_a_failed_push_refuses_without_dispatching(self):
        runner = self.passing_runner().reply(
            "git", "push", status=1, stderr="rejected: non-fast-forward"
        )
        self.assertEqual(self.drive(runner), 78)
        self.assertEqual(runner.ran("gh", "workflow", "run"), [])

    def test_a_failed_dispatch_refuses(self):
        runner = self.passing_runner().reply(
            "gh", "workflow", "run", status=1, stderr="workflow not found"
        )
        self.assertEqual(self.drive(runner), 78)

    def test_an_inert_ref_is_pushed_and_forced(self):
        runner = self.passing_runner()
        self.drive(runner, ref="preflight/tbd/lane")
        self.assertIn("--force", runner.ran("git", "push")[0])
        self.assertIn("c0ffee:refs/heads/preflight/tbd/lane", runner.ran("git", "push")[0])

    def test_a_branch_is_refused_before_it_can_be_pushed(self):
        # THE GUARD THAT MAKES "NEVER THE BRANCH" TRUE, at the one place that
        # moves a ref. Pushing the branch would publish the very commits a
        # pre-push hook is gating, and on the default branch it would
        # fast-forward `origin/main` and fire main's CI and the Pages deploy.
        for ref in ("tbd/lane", "main", "refs/heads/preflight/x", "preflight/"):
            with self.subTest(ref=ref):
                self.printed = []
                runner = self.passing_runner()
                self.assertEqual(self.drive(runner, ref=ref), 78)
                self.assertEqual(runner.ran("git", "push"), [], f"{ref} was pushed")
                self.assertEqual(runner.ran("gh", "workflow", "run"), [])

    def test_the_baseline_is_taken_before_the_dispatch(self):
        # Order is the guarantee: a baseline read after the dispatch could
        # already contain this lane's own run and would exclude it forever.
        phases = {
            ("gh", "run", "list"): "baseline",
            ("git", "push"): "push",
            ("gh", "workflow", "run"): "dispatch",
        }
        runner = self.passing_runner()
        self.drive(runner)
        order = [
            name
            for call in runner.calls
            for prefix, name in phases.items()
            if tuple(call[: len(prefix)]) == prefix
        ]
        self.assertEqual(order[:3], ["baseline", "push", "dispatch"], order)

    def test_a_stale_run_for_the_same_sha_is_not_adopted(self):
        # End to end: the run that exists before the dispatch is red, the one
        # this lane asked for is green. Adopting the stale one reports a
        # failure the lane never caused.
        stale = run_json(databaseId=1000, conclusion="failure")
        fresh = run_json(databaseId=1001, conclusion="success")
        listings = [json.dumps([stale]), json.dumps([fresh, stale])]

        def listed(argv):
            return completed(stdout=listings.pop(0) if listings else json.dumps([fresh, stale]))

        runner = self.passing_runner().reply("gh", "run", "list", handler=listed)
        # Replies match in order, so the scripted listing must win over the
        # helper's default.
        runner.replies.insert(0, runner.replies.pop())
        self.assertEqual(self.drive(runner), 0)
        viewed = runner.ran("gh", "run", "view")
        self.assertTrue(viewed, "no run was watched")
        self.assertIn("1001", viewed[0], f"the stale run was adopted: {viewed[0]}")

    def test_a_dead_requester_releases_the_ticket_without_a_verdict(self):
        runner = self.passing_runner()
        self.assertEqual(self.drive(runner, alive=lambda: False), 78)
        self.assertEqual(runner.ran("git", "push"), [], "a ref was pushed for nobody")
        self.assertEqual(runner.ran("gh", "workflow", "run"), [])
        with remote_verify.take_dispatch_ticket(self.runtime, 1) as index:
            self.assertEqual(index, 1, "the ticket outlived the requester")

    def test_an_unexpected_exception_is_a_refusal_and_never_a_failure(self):
        # 78, NOT 1. `scripts/test.sh` adopts this status as the run's own, so
        # a 1 from an unhandled OSError tells the operator the suite is red
        # when zero tests ran.
        def explode(argv):
            raise OSError("the disk filled up mid-push")

        runner = self.passing_runner().reply("git", "push", handler=explode)
        self.assertEqual(self.drive(runner), 78)

    def test_an_unusable_runtime_directory_refuses_rather_than_failing(self):
        # The ticket pool cannot be created, which is an OSError out of `mkdir`
        # from inside the context manager — the path that used to exit 1.
        blocked = self.root / "not-a-directory"
        blocked.write_text("", encoding="utf-8")
        status = remote_verify.drive(
            ref="preflight/tbd/lane", sha="c0ffee",
            runtime_dir=blocked / "runtime", slots=2,
            run_command=self.passing_runner(),
            poll=5.0, correlate_timeout=60.0, run_timeout=600.0,
            requester_alive=lambda: True,
            sleep=self.clock.sleep, monotonic=self.clock.monotonic,
            report=lambda *_: None, write=self.printed.append,
        )
        self.assertEqual(status, 78)

    def test_a_run_with_no_verdict_returns_the_lane_to_the_local_queue(self):
        runner = (
            RecordingRunner()
            .reply("gh", "run", "list", stdout=json.dumps([run_json()]))
            .reply(
                "gh", "run", "view",
                stdout=json.dumps({"status": "completed", "conclusion": "cancelled"}),
            )
        )
        self.assertEqual(self.drive(runner), 78)

    def test_the_dispatch_names_the_ref_and_the_scope(self):
        runner = self.passing_runner()
        self.drive(runner, ref="preflight/tbd/lane")
        dispatched = runner.ran("gh", "workflow", "run")[0]
        self.assertEqual(
            dispatched,
            ["gh", "workflow", "run", "test.yml", "--ref", "preflight/tbd/lane", "-f", "scope=full"],
        )

    def test_the_ticket_is_released_once_the_run_is_over(self):
        self.drive(self.passing_runner())
        with remote_verify.take_dispatch_ticket(self.runtime, 1) as index:
            self.assertEqual(index, 1)


class SettingsTests(unittest.TestCase):
    def test_the_poll_settings_default_when_unset(self):
        self.assertEqual(
            remote_verify._positive_seconds({}, remote_verify.POLL_SETTING, 10.0), 10.0
        )

    def test_a_poll_setting_overrides_the_default(self):
        self.assertEqual(
            remote_verify._positive_seconds(
                {remote_verify.POLL_SETTING: "0.5"}, remote_verify.POLL_SETTING, 10.0
            ),
            0.5,
        )

    def test_an_unreadable_duration_is_rejected_by_name(self):
        with self.assertRaises(ValueError) as caught:
            remote_verify._positive_seconds(
                {remote_verify.POLL_SETTING: "soon"}, remote_verify.POLL_SETTING, 10.0
            )
        self.assertIn(remote_verify.POLL_SETTING, str(caught.exception))

    def test_a_zero_duration_is_rejected_rather_than_obeyed(self):
        # A zero poll is not a smaller bound, it is a tight loop hammering `gh`
        # until the API rate-limits the whole account; a zero timeout refuses
        # before the first answer could arrive.
        for raw in ("0", "0.0", "-0", "nan"):
            with self.subTest(raw=raw):
                with self.assertRaises(ValueError) as caught:
                    remote_verify._positive_seconds(
                        {remote_verify.POLL_SETTING: raw}, remote_verify.POLL_SETTING, 10.0
                    )
                self.assertIn(remote_verify.POLL_SETTING, str(caught.exception))

    def test_a_zero_duration_refuses_before_anything_happens(self):
        with tempfile.TemporaryDirectory() as scratch:
            status = remote_verify.main(
                ["drive", "--repo-dir", scratch, "--ref", "preflight/tbd/lane", "--sha", "c0ffee"],
                {remote_verify.POLL_SETTING: "0", "TBD_HOME": scratch},
            )
        self.assertEqual(status, 78)

    def test_the_command_timeout_is_configurable_and_positive(self):
        self.assertEqual(
            remote_verify._positive_seconds(
                {}, remote_verify.COMMAND_SETTING, remote_verify.DEFAULT_COMMAND_SECONDS
            ),
            remote_verify.DEFAULT_COMMAND_SECONDS,
        )
        with self.assertRaises(ValueError):
            remote_verify._positive_seconds(
                {remote_verify.COMMAND_SETTING: "0"},
                remote_verify.COMMAND_SETTING,
                remote_verify.DEFAULT_COMMAND_SECONDS,
            )

    def test_an_unreadable_setting_refuses_before_anything_happens(self):
        # 78, and nothing pushed or dispatched: the repo directory here is not
        # a git repository, so even a driver that ignored the refusal could
        # only fail locally.
        with tempfile.TemporaryDirectory() as scratch:
            status = remote_verify.main(
                ["drive", "--repo-dir", scratch, "--ref", "tbd/lane", "--sha", "c0ffee"],
                {"TBD_REMOTE_VERIFY_SLOTS": "two", "TBD_HOME": scratch},
            )
        self.assertEqual(status, 78)

    def test_the_runtime_dir_follows_tbd_home(self):
        self.assertEqual(
            remote_verify._resolve_runtime_dir({"TBD_HOME": "/tmp/fixture-home"}),
            Path("/tmp/fixture-home/runtime"),
        )


class RenderCommandTests(unittest.TestCase):
    """The `render` subcommand, for reading an artifact somebody downloaded."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.dir = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def render(self, *args):
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            status = remote_verify.main(["render", *args], {})
        return status, buffer.getvalue()

    def test_a_directory_of_results_renders_and_exits_one(self):
        write_results(self.dir, **{"xunit-daemon": XCTEST_STYLE, "xunit-quiet": CLEAN_STYLE})
        status, output = self.render(str(self.dir))
        self.assertEqual(status, 1)
        self.assertIn("quarantinesProfileDirs", output)

    def test_results_with_no_failures_exit_zero(self):
        write_results(self.dir, **{"xunit-quiet": CLEAN_STYLE})
        status, output = self.render(str(self.dir))
        self.assertEqual(status, 0)
        self.assertIn("outside the test passes", output)

    def test_a_named_file_can_be_rendered_on_its_own(self):
        write_results(self.dir, **{"xunit-app": SWIFT_TESTING_STYLE})
        status, output = self.render(str(self.dir / "xunit-app.xml"))
        self.assertEqual(status, 1)
        self.assertIn("TBDAppTests.valveRoutesRemote()", output)


if __name__ == "__main__":
    unittest.main()
