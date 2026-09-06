"""Tests for scripts/claude-stub.py (stdlib only).

Mostly the pure parts: turn scripting, the env overlay, the `--print-env`
exports, the sandbox config, and the closing summary. A second group runs the
wrapper as a process against a shell script standing in for `claude`, which is
the only way to observe a real stop signal racing a real spawn. In-process
tests cover the same handler logic where a stand-in can make the timing
deterministic — driving `handle_stop_signal` directly, or handing `run_claude`
a fake `Popen` — and say so where the distinction matters. One smoke test
spawns the real `claude` against the stub end to end, and skips when no
`claude` is on PATH. The e2e suite under `.github/workflows/claude-review-v2/tests/e2e/`
exercises the same fake server, but it drives the review gate's own scenarios
and never runs this wrapper, so nothing there covers the code here.
"""

from __future__ import annotations

import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import pty
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import weakref


REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "scripts" / "claude-stub.py"


def _load_script_module():
    """Import scripts/claude-stub.py (hyphenated) as `claude_stub`."""
    loader = importlib.machinery.SourceFileLoader("claude_stub", str(SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None, f"no import spec for {SCRIPT}"
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


claude_stub = _load_script_module()


def parse(*argv: str):
    return claude_stub.parse_args(list(argv))


def recording_mkdtemp(created: list[str], tmp_root: Path):
    """A `tempfile.mkdtemp` replacement that records the sandbox it makes.

    Patched over `claude_stub.tempfile.mkdtemp`, it pins the wrapper's auto
    sandbox under `tmp_root` — which the test already reclaims, so a wrapper
    that fails to remove its own leaves nothing behind — and appends the path,
    which is how the test names a directory the wrapper never printed.
    """
    real_mkdtemp = tempfile.mkdtemp

    def mkdtemp(*args, **kwargs):
        kwargs["dir"] = str(tmp_root)
        path = real_mkdtemp(*args, **kwargs)
        created.append(path)
        return path

    return mkdtemp


class TurnScriptTests(unittest.TestCase):
    def _turns_file(self, document: object) -> str:
        handle = tempfile.NamedTemporaryFile(
            "w", suffix=".json", delete=False, encoding="utf-8"
        )
        json.dump(document, handle)
        handle.close()
        self.addCleanup(lambda: Path(handle.name).unlink(missing_ok=True))
        return handle.name

    def test_a_turn_file_can_be_a_plain_list_of_turns(self):
        path = self._turns_file(
            [
                {"text": "first"},
                {
                    "text": "second",
                    "tool_calls": [{"name": "Write", "input": {"file_path": "a.txt"}}],
                },
            ]
        )
        turns, role_turns = claude_stub.resolve_turns(parse("--turns", path))
        self.assertEqual({}, role_turns)
        self.assertEqual(["first", "second"], [turn.text for turn in turns])
        self.assertEqual([], turns[0].tool_calls)
        self.assertEqual("Write", turns[1].tool_calls[0].name)
        self.assertEqual({"file_path": "a.txt"}, turns[1].tool_calls[0].input)
        # tool_use turns must stop with tool_use, or the CLI never runs the tool.
        self.assertEqual("end_turn", turns[0].stop_reason)
        self.assertEqual("tool_use", turns[1].stop_reason)

    def test_the_object_form_carries_role_turns_for_content_keyed_routing(self):
        path = self._turns_file(
            {
                "turns": [{"text": "orchestrator"}],
                "role_turns": {
                    "ROLE-CORRECTNESS": [{"text": "correctness"}],
                    "ROLE-SECURITY": [{"text": "security 1"}, {"text": "security 2"}],
                },
            }
        )
        turns, role_turns = claude_stub.resolve_turns(parse("--turns", path))
        self.assertEqual(["orchestrator"], [turn.text for turn in turns])
        self.assertEqual({"ROLE-CORRECTNESS", "ROLE-SECURITY"}, set(role_turns))
        self.assertEqual(
            ["security 1", "security 2"],
            [turn.text for turn in role_turns["ROLE-SECURITY"]],
        )

    def test_a_turn_file_that_is_neither_a_list_nor_an_object_is_rejected(self):
        path = self._turns_file("just a string")
        with self.assertRaises(ValueError):
            claude_stub.resolve_turns(parse("--turns", path))

    def test_text_serves_exactly_one_turn_with_that_content(self):
        turns, role_turns = claude_stub.resolve_turns(parse("--text", "hello stub"))
        self.assertEqual({}, role_turns)
        self.assertEqual(["hello stub"], [turn.text for turn in turns])

    def test_the_default_answer_is_one_turn_of_n_numbered_lines(self):
        turns, role_turns = claude_stub.resolve_turns(parse("--lines", "12"))
        self.assertEqual({}, role_turns)
        self.assertEqual(1, len(turns))
        lines = turns[0].text.splitlines()
        self.assertEqual(12, len(lines))
        self.assertEqual(
            [f"{n}." for n in range(1, 13)],
            [line.split(" ", 1)[0] for line in lines],
        )

    def test_the_default_lines_count_is_two_hundred(self):
        turns, _ = claude_stub.resolve_turns(parse())
        self.assertEqual(200, len(turns[0].text.splitlines()))


class RouteTests(unittest.TestCase):
    def test_role_turns_keep_their_own_routes(self):
        role_turns = {"ROLE-SECURITY": [claude_stub.Turn(text="security")]}
        routes = claude_stub.build_routes(role_turns)
        self.assertEqual(
            ["security"], [turn.text for turn in routes["ROLE-SECURITY"]]
        )
        self.assertEqual(
            [claude_stub.TITLE_TURN], routes[claude_stub.TITLE_SENTINEL]
        )

    def test_the_reserved_title_route_beats_a_turn_file_that_claims_it(self):
        routes = claude_stub.build_routes(
            {claude_stub.TITLE_SENTINEL: [claude_stub.Turn(text="hijacked")]}
        )
        self.assertEqual(
            [claude_stub.TITLE_TURN], routes[claude_stub.TITLE_SENTINEL]
        )


class EnvOverlayTests(unittest.TestCase):
    def setUp(self):
        self.sandbox = Path(tempfile.mkdtemp(prefix="claudestub-test-"))
        self.addCleanup(shutil.rmtree, self.sandbox, ignore_errors=True)

    def test_the_harness_isolation_is_the_base(self):
        env = claude_stub.build_env(self.sandbox, "http://127.0.0.1:1", {}, {})
        self.assertEqual(str(self.sandbox), env["HOME"])
        self.assertEqual(str(self.sandbox / "config"), env["CLAUDE_CONFIG_DIR"])
        self.assertEqual("http://127.0.0.1:1", env["ANTHROPIC_BASE_URL"])
        self.assertEqual(claude_stub.STUB_API_KEY, env["ANTHROPIC_API_KEY"])

    def test_a_real_terminal_beats_the_harness_dumb_terminal(self):
        bare = claude_stub.build_env(self.sandbox, "http://127.0.0.1:1", {}, {})
        self.assertEqual("dumb", bare["TERM"])
        env = claude_stub.build_env(
            self.sandbox,
            "http://127.0.0.1:1",
            {"TERM": "xterm-256color", "COLORTERM": "truecolor", "LANG": "en_US.UTF-8"},
            {},
        )
        self.assertEqual("xterm-256color", env["TERM"])
        self.assertEqual("truecolor", env["COLORTERM"])
        self.assertEqual("en_US.UTF-8", env["LANG"])

    def test_an_empty_terminal_variable_does_not_displace_the_harness_value(self):
        env = claude_stub.build_env(self.sandbox, "http://127.0.0.1:1", {"TERM": ""}, {})
        self.assertEqual("dumb", env["TERM"])

    def test_explicit_env_beats_both_the_harness_and_the_caller(self):
        env = claude_stub.build_env(
            self.sandbox,
            "http://127.0.0.1:1",
            {"TERM": "xterm-256color"},
            claude_stub.parse_env_assignments(["TERM=vt100", "ANTHROPIC_MODEL=stub-model"]),
        )
        self.assertEqual("vt100", env["TERM"])
        self.assertEqual("stub-model", env["ANTHROPIC_MODEL"])

    def test_an_env_assignment_may_hold_equals_signs_in_its_value(self):
        self.assertEqual(
            {"A": "b=c="}, claude_stub.parse_env_assignments(["A=b=c="])
        )

    def test_an_env_argument_without_a_value_is_rejected(self):
        for bad in ("NOEQUALS", "=novalue"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                claude_stub.parse_env_assignments([bad])


class PrintEnvTests(unittest.TestCase):
    def test_export_lines_quote_values_a_shell_would_otherwise_split(self):
        lines = claude_stub.export_lines(
            {"HOME": "/tmp/a b", "NO_PROXY": "127.0.0.1,localhost", "Q": "it's"}
        )
        self.assertIn("export HOME='/tmp/a b'", lines)
        self.assertIn("export NO_PROXY=127.0.0.1,localhost", lines)
        self.assertIn("""export Q='it'"'"'s'""", lines)

    def test_export_lines_are_sorted_so_the_block_is_stable(self):
        lines = claude_stub.export_lines({"B": "2", "A": "1"})
        self.assertEqual(["export A=1", "export B=2"], lines)

    def test_the_callers_own_path_is_not_re_exported(self):
        lines = claude_stub.export_lines({"PATH": "/usr/bin", "HOME": "/tmp/x"})
        self.assertEqual(["export HOME=/tmp/x"], lines)

    def test_a_path_the_caller_overrode_with_env_is_exported(self):
        # The run mode honours --env PATH=..., so --print-env must too.
        lines = claude_stub.export_lines(
            {"PATH": "/opt/stub/bin", "HOME": "/tmp/x"}, {"PATH": "/opt/stub/bin"}
        )
        self.assertEqual(["export HOME=/tmp/x", "export PATH=/opt/stub/bin"], lines)

    def test_overriding_an_unrelated_variable_still_drops_the_inherited_path(self):
        lines = claude_stub.export_lines(
            {"PATH": "/usr/bin", "HOME": "/tmp/x"}, {"TERM": "vt100"}
        )
        self.assertEqual(["export HOME=/tmp/x"], lines)


class SummaryTests(unittest.TestCase):
    def _server(self, **kwargs):
        from stub_server import StubServer, Turn

        server = StubServer([Turn(text="one")], **kwargs)
        self.addCleanup(server._httpd.server_close)
        return server

    @staticmethod
    def _env(server, base_url=None):
        """The env claude was handed; by default the one aimed at this server."""
        return {"ANTHROPIC_BASE_URL": base_url or server.base_url}

    def test_the_summary_counts_requests_and_names_the_loopback_url(self):
        server = self._server()
        server.capture.raw_bodies.extend([b"{}", b"{}"])
        server.capture.routes.extend([None, None])
        lines = claude_stub.summary_lines(server, self._env(server))
        self.assertIn(f"2 request(s) served at {server.base_url}", lines)
        self.assertIn(
            "no model request left this machine — ANTHROPIC_BASE_URL was "
            f"{server.base_url} (loopback)",
            lines,
        )

    def test_an_overridden_base_url_is_reported_instead_of_a_loopback_claim(self):
        # --env ANTHROPIC_BASE_URL=... points claude somewhere the stub cannot
        # see, so the summary must not vouch for traffic it never observed.
        server = self._server()
        server.capture.raw_bodies.append(b"{}")
        server.capture.routes.append(None)
        lines = claude_stub.summary_lines(
            server, self._env(server, "https://api.example.invalid")
        )
        self.assertIn(
            "ANTHROPIC_BASE_URL was overridden to https://api.example.invalid; "
            "the stub served 1 request(s), and requests to that URL are not "
            "counted here",
            lines,
        )
        self.assertFalse([line for line in lines if "loopback" in line])

    def test_the_connectivity_preflight_is_not_reported_as_unexpected(self):
        server = self._server()
        server.capture.unexpected_paths.extend(["/api/hello", "/v1/messages/count_tokens"])
        lines = claude_stub.summary_lines(server, self._env(server))
        self.assertIn("unexpected paths: /v1/messages/count_tokens", lines)

    def test_routes_are_broken_out_when_the_run_uses_content_keyed_routing(self):
        server = self._server(
            role_turns={
                claude_stub.TITLE_SENTINEL: [claude_stub.TITLE_TURN],
                "ROLE-SECURITY": [],
            }
        )
        server.capture.raw_bodies.extend([b"{}", b"{}", b"{}"])
        server.capture.routes.extend([claude_stub.TITLE_SENTINEL, "ROLE-SECURITY", None])
        lines = claude_stub.summary_lines(server, self._env(server))
        self.assertIn(f"  route {claude_stub.TITLE_LABEL}: 1", lines)
        self.assertIn("  route ROLE-SECURITY: 1", lines)
        self.assertIn("  route (ordered turns): 1", lines)

    def test_a_run_without_routing_reports_no_route_breakdown(self):
        server = self._server()
        server.capture.raw_bodies.append(b"{}")
        server.capture.routes.append(None)
        lines = claude_stub.summary_lines(server, self._env(server))
        self.assertFalse([line for line in lines if line.startswith("  route ")])


class ConfigTests(unittest.TestCase):
    def _sandbox(self) -> Path:
        sandbox = Path(tempfile.mkdtemp(prefix="claudestub-test-"))
        self.addCleanup(shutil.rmtree, sandbox, ignore_errors=True)
        return sandbox

    def test_the_config_pre_accepts_trust_and_the_custom_api_key_dialog(self):
        sandbox = self._sandbox()
        project = sandbox / "project"
        project.mkdir()
        claude_stub.write_config(sandbox, project)
        config = json.loads(
            (sandbox / "config" / ".claude.json").read_text(encoding="utf-8")
        )
        self.assertTrue(config["hasTrustDialogAccepted"])
        self.assertTrue(config["projects"][str(project)]["hasTrustDialogAccepted"])
        # The interactive TUI otherwise stops on "use this API key?". The
        # approved fingerprint must be of the key claude actually gets, so it
        # is checked against the env rather than against a restated literal.
        env = claude_stub.build_env(sandbox, "http://127.0.0.1:1", {}, {})
        self.assertEqual(
            [env["ANTHROPIC_API_KEY"][-20:]],
            config["customApiKeyResponses"]["approved"],
        )

    def test_a_reused_sandbox_keeps_its_transcripts_and_gains_the_new_project(self):
        sandbox = self._sandbox()
        first, second = sandbox / "one", sandbox / "two"
        first.mkdir()
        second.mkdir()
        claude_stub.write_config(sandbox, first)
        transcript = sandbox / "config" / "projects" / "session.jsonl"
        transcript.parent.mkdir(parents=True)
        transcript.write_text("{}\n", encoding="utf-8")

        claude_stub.write_config(sandbox, second)  # second run, different cwd

        self.assertTrue(transcript.is_file(), "the reused sandbox lost its transcripts")
        config = json.loads(
            (sandbox / "config" / ".claude.json").read_text(encoding="utf-8")
        )
        self.assertTrue(config["hasTrustDialogAccepted"])
        for project in (first, second):
            self.assertTrue(config["projects"][str(project)]["hasTrustDialogAccepted"])


def signal_from_a_context_that_ignores_exceptions(signum: int) -> None:
    """Deliver `signum` to this process from inside a weakref callback.

    The shape the flake takes, made deterministic. A Python signal handler
    runs at whatever bytecode boundary the interpreter reaches next, and CPython
    invokes some Python from places that print any exception as an
    `Exception ignored …` line and carry on — a weakref callback here, an
    import-lock release callback in the run that was captured off CI. A
    handler that answers a stop signal by raising is silently disarmed there:
    the signal is neither delivered nor recorded, and the wrapper walks on to
    spawn `claude` and wait on it forever.

    A self-directed `os.kill` is delivered before it returns, so the pending
    handler runs at the loop that follows it — inside the callback, which is
    the whole point.
    """
    class Carrier:
        pass

    carrier = Carrier()

    def ignored_context(_ref):
        os.kill(os.getpid(), signum)
        # A backward jump, so the interpreter certainly reaches a point where
        # it runs the pending handler before this callback returns.
        for _ in range(64):
            pass

    keep_alive = weakref.ref(carrier, ignored_context)
    # The wrapper's own handlers, so the signal takes the route it takes in a
    # real run. Installing them is idempotent — inside `main` they are already
    # on, and restoring puts back exactly what was there — and without them a
    # unit test that drives the handler directly would be killed by the
    # default disposition instead.
    previous = claude_stub.install_signal_handlers()
    try:
        del carrier
    finally:
        claude_stub.restore_signal_handlers(previous)
    assert keep_alive() is None, "the weakref callback did not run"


class FakeChild:
    """Stands in for `subprocess.Popen`, recording what was sent to it."""

    def __init__(self, send_error: BaseException | None = None) -> None:
        self.sent: list[int] = []
        self.send_error = send_error

    def send_signal(self, signum: int) -> None:
        self.sent.append(signum)
        if self.send_error is not None:
            raise self.send_error


class SignalTargetsFixture(unittest.TestCase):
    """A private `SignalTargets` for tests that drive the handler directly.

    `handle_stop_signal` reads the module global, and `finishing` is a one-way
    latch, so a test that set it on the real one would silence every later
    in-process test that expects a signal to be acted on.
    """

    def setUp(self):
        self.targets = claude_stub.SignalTargets()
        patch = mock.patch.object(claude_stub, "SIGNAL_TARGETS", self.targets)
        patch.start()
        self.addCleanup(patch.stop)


class SignalHandlerStateTests(SignalTargetsFixture):
    def test_a_stop_signal_while_finishing_is_recorded_and_swallowed(self):
        # After the child is waited for there is nothing to forward to and
        # nothing to unwind: raising here would replace the child's status and
        # could interrupt the sandbox removal.
        child = FakeChild()
        self.targets.child = child
        self.targets.finishing = True

        self.assertIsNone(claude_stub.handle_stop_signal(signal.SIGTERM, None))

        self.assertEqual([], child.sent, "a finishing run still forwarded")
        self.assertEqual([int(signal.SIGTERM)], self.targets.late_signums)

    def test_a_stop_signal_with_nothing_finishing_still_terminates(self):
        # The discriminator for the test above: without `finishing`, a signal
        # nobody owns is still the `Terminated` that unwinds through cleanup —
        # recorded by the handler, raised by the next `raise_if_stopped`,
        # because a handler that raises where it stands can have its exception
        # thrown away by the context it landed in.
        self.assertIsNone(claude_stub.handle_stop_signal(signal.SIGHUP, None))
        self.assertEqual([int(signal.SIGHUP)], self.targets.unowned_signums)
        self.assertEqual([], self.targets.late_signums)

        with self.assertRaises(claude_stub.Terminated) as raised:
            claude_stub.raise_if_stopped()
        self.assertEqual(int(signal.SIGHUP), raised.exception.signum)
        # Consumed: the same signal must not unwind a second run of the
        # cleanup it already unwound.
        self.assertEqual([], self.targets.unowned_signums)
        claude_stub.raise_if_stopped()

    def test_a_live_child_is_still_sent_the_signal(self):
        child = FakeChild()
        self.targets.child = child
        self.assertIsNone(claude_stub.handle_stop_signal(signal.SIGTERM, None))
        self.assertEqual([int(signal.SIGTERM)], child.sent)

    def _handle_with_predicate(self, signum: int, already_delivered: bool) -> list[int]:
        """Signal a live child with the foreground-group answer forced."""
        child = FakeChild()
        self.targets.child = child
        with mock.patch.object(
            claude_stub, "sigint_reached_child_already", return_value=already_delivered
        ):
            self.assertIsNone(claude_stub.handle_stop_signal(signum, None))
        return child.sent

    def test_a_terminal_ctrl_c_is_not_forwarded_to_the_child_a_second_time(self):
        # The tty already delivered it to the whole foreground process group,
        # which the child shares; the TUI exits on a double Ctrl-C, so a second
        # one would answer the user's first press with the exit confirmation.
        # The rule is by position, so a `kill -INT` at a foreground wrapper is
        # dropped with the keypress — SIGTERM is the way to stop it from
        # outside.
        self.assertEqual([], self._handle_with_predicate(signal.SIGINT, True))

    def test_a_sigint_from_outside_the_foreground_group_is_forwarded(self):
        # No controlling terminal, or the wrapper in the background: nothing
        # but this wrapper can have handed the child that signal.
        self.assertEqual(
            [int(signal.SIGINT)], self._handle_with_predicate(signal.SIGINT, False)
        )

    def test_a_sigterm_is_forwarded_whatever_the_terminal_did(self):
        # Only SIGINT can reach the child by the tty, so the check must not
        # start swallowing signals that arrive by no route but this one.
        for shared in (True, False):
            with self.subTest(shared=shared):
                self.assertEqual(
                    [int(signal.SIGTERM)],
                    self._handle_with_predicate(signal.SIGTERM, shared),
                )

    def test_forwarding_tolerates_a_child_that_exited_first(self):
        # The race every forwarding site runs: the pid is gone by the time the
        # signal is sent, which is the outcome that was wanted, not a crash.
        child = FakeChild(send_error=ProcessLookupError())
        claude_stub.forward(child, signal.SIGINT)
        self.assertEqual([int(signal.SIGINT)], child.sent)

    def test_forwarding_a_signal_to_a_live_child_delivers_it(self):
        child = FakeChild()
        claude_stub.forward(child, signal.SIGTERM)
        self.assertEqual([int(signal.SIGTERM)], child.sent)

    def test_the_serving_cleanup_order_leaves_no_gap_for_a_late_signal(self):
        # `serve_until_signalled`'s `finally` latches `finishing` before
        # clearing `serving_event`, the same order `run_claude`'s `finally`
        # latches `finishing` before dropping `child`: a signal landing
        # between the two statements finds `finishing` already set and is
        # recorded and swallowed rather than raising `Terminated`.
        self.targets.serving_event = claude_stub.threading.Event()

        self.targets.finishing = True
        self.assertIsNone(claude_stub.handle_stop_signal(signal.SIGTERM, None))
        self.targets.serving_event = None

        self.assertEqual([int(signal.SIGTERM)], self.targets.late_signums)

    def test_the_old_gap_between_finishing_and_serving_event_would_terminate(self):
        # The discriminator for the test above: with `finishing` still False
        # and `serving_event` already cleared — the reversed order the bug
        # produced — the handler has nothing to hand the signal to, so it is
        # recorded and unwound as `Terminated` rather than swallowed.
        self.targets.serving_event = None
        self.targets.finishing = False

        self.assertIsNone(claude_stub.handle_stop_signal(signal.SIGTERM, None))
        self.assertEqual([], self.targets.late_signums, "swallowed while running")
        with self.assertRaises(claude_stub.Terminated) as raised:
            claude_stub.raise_if_stopped()
        self.assertEqual(int(signal.SIGTERM), raised.exception.signum)

    def test_a_stop_signal_is_never_lost_where_exceptions_are_ignored(self):
        # The flake this file is armed against: on a loaded runner the signal
        # lands somewhere CPython throws the handler's exception away. Every
        # branch of the handler has to answer by recording or forwarding and
        # returning, so none of them can be disarmed that way.
        for owner, expect in (
            ("nothing", "unowned"),
            ("child", "forwarded"),
            ("spawning", "queued"),
            ("serving", "event"),
            ("finishing", "late"),
        ):
            with self.subTest(owner=owner):
                targets = claude_stub.SignalTargets()
                child = FakeChild()
                event = claude_stub.threading.Event()
                if owner == "child":
                    targets.child = child
                elif owner == "spawning":
                    targets.spawning = True
                elif owner == "serving":
                    targets.serving_event = event
                elif owner == "finishing":
                    targets.finishing = True
                with mock.patch.object(claude_stub, "SIGNAL_TARGETS", targets), \
                     mock.patch.object(
                         claude_stub, "sigint_reached_child_already", return_value=False
                     ):
                    signal_from_a_context_that_ignores_exceptions(signal.SIGTERM)

                answered = {
                    "unowned": targets.unowned_signums == [int(signal.SIGTERM)],
                    "forwarded": child.sent == [int(signal.SIGTERM)],
                    "queued": targets.pending_signum == int(signal.SIGTERM),
                    "event": event.is_set(),
                    "late": targets.late_signums == [int(signal.SIGTERM)],
                }
                # The whole shape, not just the expected key: exactly one
                # branch answers, and none of the others is quietly firing too.
                self.assertEqual(
                    {key: key == expect for key in answered},
                    answered,
                    f"the {owner} branch answered a signal raised into an "
                    "exception-ignoring context wrongly",
                )

    def test_a_recorded_stop_signal_unwinds_instead_of_spawning_claude(self):
        # The arming in `run_claude` is where a recorded signal stops being
        # anybody's: past it, `spawning` is set and the record is never read
        # again. So the check and the latch are one atomic step, and a signal
        # already recorded must unwind rather than spawn a child that the
        # wrapper would then wait on forever.
        self.targets.unowned_signums = [int(signal.SIGTERM)]

        def popen(*_args, **_kwargs):
            self.fail("spawned claude with a stop signal already recorded")

        with mock.patch.object(claude_stub.subprocess, "Popen", popen):
            with self.assertRaises(claude_stub.Terminated) as raised:
                claude_stub.run_claude("claude", [], {})
        self.assertEqual(int(signal.SIGTERM), raised.exception.signum)
        self.assertFalse(self.targets.spawning, "the spawn stayed armed")


class LateSignalExitStatusTests(SignalTargetsFixture):
    def test_a_signal_after_the_child_exits_keeps_the_status_and_cleans_up(self):
        # A self-signal is delivered to the calling thread before `os.kill`
        # returns, so this lands exactly in the window between the child being
        # waited for and `main` finishing its cleanup. Unswallowed it becomes
        # a `Terminated`: status 143 instead of 7, out of a `shutil.rmtree`
        # that may have walked only half the sandbox.
        root = Path(tempfile.mkdtemp(prefix="claudestub-test-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        created: list[str] = []

        def finishing_then_signalled(binary, claude_args, env):
            claude_stub.SIGNAL_TARGETS.finishing = True
            os.kill(os.getpid(), signal.SIGTERM)
            return 7

        with mock.patch.object(
            claude_stub.tempfile, "mkdtemp", recording_mkdtemp(created, root)
        ):
            with mock.patch.object(
                claude_stub, "run_claude", finishing_then_signalled
            ):
                status = claude_stub.main(["--text", "x", "--", "-p", "hi"])

        self.assertEqual(7, status)
        self.assertEqual([int(signal.SIGTERM)], self.targets.late_signums)
        self.assertEqual(1, len(created), "the wrapper did not create a temp sandbox")
        self.assertFalse(Path(created[0]).exists(), "the temp sandbox leaked")


class CrossCallSignalBookkeepingTests(SignalTargetsFixture):
    """`SIGNAL_TARGETS` is module-level, so it outlives a single `main` call.

    Every in-process test in this file calls `claude_stub.main` against the
    same global (or, under `SignalTargetsFixture`, the same patched stand-in
    for the run's whole lifetime), so a process — or a test run — that calls
    `main` more than once is the normal case here, not an edge case. Before
    the reset at the top of `main`, `late_signums` was never cleared at all
    and `finishing` stayed `True` from the previous run's own cleanup, so a
    second run reported a signal the first run had already answered for
    itself, and would have swallowed every stop signal of its own the moment
    one arrived.
    """

    def test_a_second_run_does_not_report_or_reuse_the_first_runs_late_signal(self):
        root = Path(tempfile.mkdtemp(prefix="claudestub-test-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        missing = root / "no-such-claude"
        created: list[str] = []

        def finishing_then_signalled(binary, claude_args, env):
            claude_stub.SIGNAL_TARGETS.finishing = True
            # Delivered before `os.kill` returns, so it lands with `finishing`
            # already set and is recorded as late rather than as unowned.
            os.kill(os.getpid(), signal.SIGTERM)
            return 7

        stderr_first = io.StringIO()
        with contextlib.redirect_stderr(stderr_first), mock.patch.object(
            claude_stub.tempfile, "mkdtemp", recording_mkdtemp(created, root)
        ), mock.patch.object(claude_stub, "run_claude", finishing_then_signalled):
            first_status = claude_stub.main(
                ["--text", "x", "--claude-binary", str(missing), "--", "-p", "hi"]
            )

        self.assertEqual(7, first_status)
        self.assertEqual([int(signal.SIGTERM)], self.targets.late_signums)
        self.assertIn(
            f"signal {int(signal.SIGTERM)} arrived while exiting; nothing left to stop",
            stderr_first.getvalue(),
        )

        # A second run, same process, same patched `SIGNAL_TARGETS` — no
        # signal of its own, and a `--claude-binary` guaranteed missing so the
        # run ends deterministically without spawning anything real.
        stderr_second = io.StringIO()
        with contextlib.redirect_stderr(stderr_second), mock.patch.object(
            claude_stub.tempfile, "mkdtemp", recording_mkdtemp(created, root)
        ):
            second_status = claude_stub.main(
                ["--text", "y", "--claude-binary", str(missing), "--", "-p", "hi"]
            )

        self.assertEqual(127, second_status, "nothing left to stop, nothing signalled")
        self.assertNotIn(
            "arrived while exiting",
            stderr_second.getvalue(),
            "the second run reported a signal the first run already answered",
        )
        self.assertEqual(
            [],
            self.targets.late_signums,
            "the first run's late signal was never cleared for the second",
        )


class SignalTargetsFiringWhenTheResetBegins(claude_stub.SignalTargets):
    """A `SignalTargets` that self-signals at the first statement of the reset.

    `main` clears `late_signums`, `unowned_signums` and `finishing` at the top
    of every run. Those are three plain assignments with no call between them,
    so — as with `SignalTargetsFiringWhenTheSpawnDisarms` — the state
    transition itself is the only clock a test can hang a signal off: the
    setter fires while `finishing` is still `True` from the previous run and
    `_late_signums` is still the previous run's list, which is exactly the
    window the mask around the reset exists to close.
    """

    def __init__(self, signum: int) -> None:
        self._signum = signum
        self._armed = False
        # Sets `late_signums`, hence the setter, hence `_armed` first.
        super().__init__()

    def arm(self) -> None:
        """Fire on the next reset — the second `main` call, not the first."""
        self._armed = True

    @property
    def late_signums(self) -> list[int]:
        return self._late_signums

    @late_signums.setter
    def late_signums(self, value: list[int]) -> None:
        if self._armed:
            self._armed = False
            signal_from_a_context_that_ignores_exceptions(self._signum)
        self._late_signums = value


class ResetWindowSignalTests(unittest.TestCase):
    """A stop signal landing inside `main`'s own per-run reset.

    The reset is not reached with the handler in a known state: `main` calls
    `restore_signal_handlers` on its way out, so by the second call the
    process holds whatever disposition it had before the first — the default
    one in this harness, and `handle_stop_signal` itself for any embedder that
    shares the wrapper's handler machinery. This exercises the second: the
    same function is installed across the reset as after it, so what
    discriminates is purely *when* it runs relative to the three assignments.
    Run unmasked it reads `finishing == True` left by the first run and
    swallows the signal onto a `late_signums` the next statement throws away —
    `raise_if_stopped` only ever consults `unowned_signums`, so the run walks
    on and spawns `claude`. Held off across the reset it lands on a fully reset
    state, is recorded as unowned, and the first checkpoint — before the
    sandbox exists — unwinds it.
    """

    def test_a_stop_signal_inside_the_reset_stops_the_second_run(self):
        for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            with self.subTest(signum=int(signum)):
                self._assert_the_reset_window_signal_stops_the_run(int(signum))

    def _assert_the_reset_window_signal_stops_the_run(self, signum: int) -> None:
        root = Path(tempfile.mkdtemp(prefix="claudestub-test-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        marker = root / "claude-ran.txt"
        binary = root / "fake-claude.sh"
        binary.write_text(
            f"#!/bin/sh\ntouch {shlex.quote(str(marker))}\n", encoding="utf-8"
        )
        binary.chmod(0o755)
        created: list[str] = []
        targets = SignalTargetsFiringWhenTheResetBegins(signum)
        argv = ["--text", "x", "--claude-binary", str(binary), "--", "-p", "hi"]

        with contextlib.redirect_stderr(io.StringIO()), mock.patch.object(
            claude_stub, "SIGNAL_TARGETS", targets
        ), mock.patch.object(
            claude_stub.tempfile, "mkdtemp", recording_mkdtemp(created, root)
        ):
            # A first, unsignalled run purely to leave the latch set: `main`'s
            # cleanup sets `finishing` on every exit, and that leftover `True`
            # is what makes the half-reset state misread a signal.
            self.assertEqual(0, claude_stub.main(argv))
            self.assertTrue(targets.finishing, "the first run left no latch to race")
            self.assertTrue(marker.exists(), "the first run never spawned claude")
            marker.unlink()

            # The state the finding describes: an embedder that left the
            # wrapper's own handler installed between the two calls, so the
            # reset-window signal is recorded rather than taking the default
            # disposition and killing this test process.
            previous = claude_stub.install_signal_handlers()
            self.addCleanup(claude_stub.restore_signal_handlers, previous)
            targets.arm()
            status = claude_stub.main(argv)

        self.assertEqual(128 + signum, status, "the reset-window signal was lost")
        self.assertFalse(marker.exists(), "claude was spawned after the stop signal")
        for path in created:
            self.assertFalse(Path(path).exists(), "a temp sandbox leaked")


class SignalTargetsFiringWhenTheSpawnDisarms(claude_stub.SignalTargets):
    """A `SignalTargets` that self-signals the instant `spawning` clears.

    `run_claude` clears `spawning` in a `finally` and only then decides what to
    do about a failed spawn, so on the binary-not-found path there are a few
    bytecodes in which no phase owns a stop signal. Nothing in that stretch is
    a function call, so there is no seam to patch: the state transition itself
    is the clock, and overriding the attribute is how a test can fire a signal
    into the window on every run rather than on a slow one.
    """

    def __init__(self, signum: int) -> None:
        self._signum = signum
        self._fired = False
        super().__init__()

    @property
    def spawning(self) -> bool:
        return self._spawning

    @spawning.setter
    def spawning(self, value: bool) -> None:
        was_spawning = getattr(self, "_spawning", False)
        self._spawning = value
        # Only the arm-then-disarm transition, and only once: `__init__` sets
        # the attribute False before any spawn has been armed.
        if was_spawning and not value and not self._fired:
            self._fired = True
            signal_from_a_context_that_ignores_exceptions(self._signum)


class SignalTargetsQueueingThenFiringWhenTheSpawnDisarms(claude_stub.SignalTargets):
    """A `SignalTargets` that ends the spawn holding two distinct signals.

    Arming the spawn parks `queued` in `pending_signum`, which is what the
    handler does when a stop signal lands inside `Popen` — a window
    microseconds wide that cannot be hit on demand, and the same stand-in
    `QueuedSpawnSignalTests` uses. Disarming it then fires `unowned` for real,
    from a context that discards exceptions, so it takes the handler's
    ownerless branch in the one stretch of the failed-spawn path where no
    phase owns a stop signal.

    The pair is the shape the failed-spawn path has to answer for: `queued`
    arrived first and owns the exit status, `unowned` arrived second and can
    only be reported, and a run that surfaces one of the two is
    indistinguishable from a run that was sent one signal.
    """

    def __init__(self, queued: int, unowned: int) -> None:
        self._queued = queued
        self._unowned = unowned
        self._fired = False
        super().__init__()

    @property
    def spawning(self) -> bool:
        return self._spawning

    @spawning.setter
    def spawning(self, value: bool) -> None:
        was_spawning = getattr(self, "_spawning", False)
        self._spawning = value
        if not was_spawning and value:
            # `run_claude` clears `pending_signum` and arms `spawning` under
            # the mask, so the queue is filled after the arming rather than
            # before it — the order a real handler firing inside `Popen`
            # produces.
            self.pending_signum = self._queued
        elif was_spawning and not value and not self._fired:
            self._fired = True
            signal_from_a_context_that_ignores_exceptions(self._unowned)


class StopSignalDroppedByAnIgnoredContextTests(SignalTargetsFixture):
    """The window the ubuntu harness job kept failing in, made deterministic.

    On a loaded runner a stop signal sent the instant the sandbox appears can
    be handled at a bytecode boundary CPython discards exceptions from. A
    handler that answered by raising was disarmed there: the signal vanished
    with an `Exception ignored …` line, `main` walked on to spawn `claude`
    and blocked in `child.wait()` for as long as the child lived — which the
    five-shot subprocess tests below caught as "the wrapper did not finish
    30.0s after signal 15" a few percent of the time.

    Nothing here races: the signal is fired from inside a weakref callback at
    a named point in the run, so the drop is reproduced on every run rather
    than on a slow one.
    """

    def _main_with_the_signal_fired_inside(self, target: str, signum: int):
        """Run `main` with `target` firing a self-signal from an ignored context."""
        root = Path(tempfile.mkdtemp(prefix="claudestub-test-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        marker = root / "claude-ran.txt"
        binary = root / "fake-claude.sh"
        binary.write_text(
            f"#!/bin/sh\ntouch {shlex.quote(str(marker))}\n", encoding="utf-8"
        )
        binary.chmod(0o755)
        created: list[str] = []
        real = getattr(claude_stub, target)

        def fire(*args, **kwargs):
            result = real(*args, **kwargs)
            signal_from_a_context_that_ignores_exceptions(signum)
            return result

        # A `SignalTargets` per run, not the fixture's: `main` latches
        # `finishing` on its way out, and a second run sharing that latch
        # would have its signal swallowed for a reason this test is not about.
        with mock.patch.object(
            claude_stub, "SIGNAL_TARGETS", claude_stub.SignalTargets()
        ), mock.patch.object(
            claude_stub.tempfile, "mkdtemp", recording_mkdtemp(created, root)
        ), mock.patch.object(claude_stub, target, fire):
            status = claude_stub.main(
                ["--text", "x", "--claude-binary", str(binary), "--", "-p", "hi"]
            )
        self.assertEqual(1, len(created), "the wrapper did not create a temp sandbox")
        return status, Path(created[0]), marker

    def test_a_dropped_stop_signal_still_stops_the_run(self):
        # `write_config` puts the signal between the sandbox existing and the
        # stub server binding; `build_env` puts it after the server is up and
        # inside the `with`, the last stretch before the spawn is armed. Both
        # are points the wrapper passes on every run, and neither has anything
        # that can take a signal, so both are the flake's window.
        for target in ("write_config", "build_env"):
            for signum in (signal.SIGTERM, signal.SIGINT):
                with self.subTest(target=target, signum=int(signum)):
                    status, sandbox, marker = self._main_with_the_signal_fired_inside(
                        target, signum
                    )
                    self.assertEqual(128 + int(signum), status)
                    self.assertFalse(sandbox.exists(), "the temp sandbox leaked")
                    self.assertFalse(
                        marker.exists(), "claude was spawned after the stop signal"
                    )

    def test_a_signal_recorded_in_the_last_gap_is_reported_rather_than_lost(self):
        # The backstop for the instants between a `raise_if_stopped` and the
        # latch that gives the next phase an owner: nothing will unwind such a
        # record, so `main`'s cleanup reports it with the late signals instead
        # of dropping it, and the status stays the one the run produced.
        root = Path(tempfile.mkdtemp(prefix="claudestub-test-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        created: list[str] = []

        def recorded_then_returned(binary, claude_args, env):
            claude_stub.SIGNAL_TARGETS.unowned_signums.append(int(signal.SIGHUP))
            return 3

        with mock.patch.object(
            claude_stub.tempfile, "mkdtemp", recording_mkdtemp(created, root)
        ), mock.patch.object(claude_stub, "run_claude", recorded_then_returned):
            status = claude_stub.main(["--text", "x", "--", "-p", "hi"])

        self.assertEqual(3, status)
        self.assertEqual([int(signal.SIGHUP)], self.targets.late_signums)
        self.assertFalse(Path(created[0]).exists(), "the temp sandbox leaked")

    def test_a_stop_signal_in_the_binary_not_found_window_is_still_a_stop(self):
        # The one window on the failed-spawn path with no owner: `spawning`
        # has just been cleared, no child was ever published, and `finishing`
        # is not latched yet. The handler can only record such a signal, and
        # before the fix nothing read the record — `main`'s cleanup promoted it
        # to a late signal, so the wrapper answered 127 with "nothing left to
        # stop" for a stop it had genuinely been sent. It must unwind as
        # `Terminated` like every other ownerless stop: 128 + signum, and the
        # sandbox reclaimed on the way out.
        for signum in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signum=int(signum)):
                root = Path(tempfile.mkdtemp(prefix="claudestub-test-"))
                self.addCleanup(shutil.rmtree, root, ignore_errors=True)
                created: list[str] = []
                # Never created, so `Popen` raises `FileNotFoundError` for
                # real rather than through a stand-in.
                missing = root / "no-such-claude"
                targets = SignalTargetsFiringWhenTheSpawnDisarms(int(signum))

                with mock.patch.object(
                    claude_stub, "SIGNAL_TARGETS", targets
                ), mock.patch.object(
                    claude_stub.tempfile, "mkdtemp", recording_mkdtemp(created, root)
                ):
                    status = claude_stub.main(
                        [
                            "--text",
                            "x",
                            "--claude-binary",
                            str(missing),
                            "--",
                            "-p",
                            "hi",
                        ]
                    )

                self.assertEqual(
                    128 + int(signum),
                    status,
                    "the stop signal was swallowed by the not-found path",
                )
                self.assertEqual(
                    1, len(created), "the wrapper did not create a temp sandbox"
                )
                self.assertFalse(Path(created[0]).exists(), "the temp sandbox leaked")

    def test_a_second_signal_on_the_failed_spawn_path_reaches_the_summary(self):
        # Two distinct stops on the binary-not-found path: one queued across
        # the spawn, one landing ownerless in the window after `spawning`
        # clears. The queued one arrived first and is the status; the second
        # can only be reported — and reporting it is the half that was
        # missing. The failed-spawn branch used to raise `Terminated` straight
        # out, skipping the mask-check-latch its siblings use, and the
        # exiting-summary line sat on `main`'s normal-return path, which a
        # propagating `Terminated` never reaches. `main`'s cleanup promoted
        # the second signal into `late_signums` and nothing ever printed it,
        # so a run sent two stops was indistinguishable from one sent one.
        root = Path(tempfile.mkdtemp(prefix="claudestub-test-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        created: list[str] = []
        # Never created, so `Popen` raises `FileNotFoundError` for real.
        missing = root / "no-such-claude"
        queued, unowned = int(signal.SIGTERM), int(signal.SIGHUP)
        targets = SignalTargetsQueueingThenFiringWhenTheSpawnDisarms(queued, unowned)

        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), mock.patch.object(
            claude_stub, "SIGNAL_TARGETS", targets
        ), mock.patch.object(
            claude_stub.tempfile, "mkdtemp", recording_mkdtemp(created, root)
        ):
            status = claude_stub.main(
                ["--text", "x", "--claude-binary", str(missing), "--", "-p", "hi"]
            )

        self.assertEqual(
            128 + queued, status, "the queued signal did not produce the status"
        )
        written = stderr.getvalue()
        self.assertIn(f"stopped by signal {queued}", written)
        self.assertIn(
            f"signal {unowned} arrived while exiting; nothing left to stop",
            written,
            "the second signal was recorded but never reported",
        )
        self.assertEqual([unowned], targets.late_signums)
        self.assertEqual(1, len(created), "the wrapper did not create a temp sandbox")
        self.assertFalse(Path(created[0]).exists(), "the temp sandbox leaked")

    def test_a_signal_during_the_failed_spawn_unwind_does_not_clobber_the_record(self):
        # What the masked check-and-latch buys over raising straight out. The
        # `Terminated` unwinds through the stub server's `__exit__` — a socket
        # shutdown and a thread join — before `main`'s cleanup latches
        # `finishing`. Raised ahead of the latch, a third stop arriving in
        # that stretch is taken by the handler's ownerless branch and
        # appended to `unowned_signums` — a list, so nothing is destroyed on
        # write — but it would then wait for `main`'s cleanup to promote it
        # rather than reaching `late_signums` directly. Latched first, the
        # handler appends it to `late_signums` itself, so all three survive
        # equally: the first as the status, the other two in the summary, in
        # order.
        root = Path(tempfile.mkdtemp(prefix="claudestub-test-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        created: list[str] = []
        missing = root / "no-such-claude"
        queued, unowned = int(signal.SIGTERM), int(signal.SIGHUP)
        during_unwind = int(signal.SIGINT)
        targets = SignalTargetsQueueingThenFiringWhenTheSpawnDisarms(queued, unowned)

        class ServerFiringOnTheWayOut(claude_stub.StubServer):
            """Fires the third signal from the `__exit__` the unwind passes."""

            def __exit__(self, *exc: object) -> None:
                signal_from_a_context_that_ignores_exceptions(during_unwind)
                return super().__exit__(*exc)

        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), mock.patch.object(
            claude_stub, "SIGNAL_TARGETS", targets
        ), mock.patch.object(
            claude_stub, "StubServer", ServerFiringOnTheWayOut
        ), mock.patch.object(
            claude_stub.tempfile, "mkdtemp", recording_mkdtemp(created, root)
        ):
            status = claude_stub.main(
                ["--text", "x", "--claude-binary", str(missing), "--", "-p", "hi"]
            )

        self.assertEqual(128 + queued, status)
        self.assertEqual(
            [unowned, during_unwind],
            targets.late_signums,
            "a signal arriving during the unwind overwrote the earlier record",
        )
        self.assertIn(
            f"signals {unowned}, {during_unwind} arrived while exiting; "
            "nothing left to stop",
            stderr.getvalue(),
        )
        self.assertFalse(Path(created[0]).exists(), "the temp sandbox leaked")

    def test_both_stop_signals_in_the_exit_window_are_reported(self):
        # Two arrive: one recorded as unowned in a gap nothing unwinds, one
        # taken by the handler after `finishing` is latched. Reporting a single
        # slot made the pair indistinguishable from a run that got one signal,
        # so both are kept, in arrival order, and both reach the summary.
        root = Path(tempfile.mkdtemp(prefix="claudestub-test-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        created: list[str] = []

        def recorded_then_signalled_while_finishing(binary, claude_args, env):
            claude_stub.SIGNAL_TARGETS.unowned_signums.append(int(signal.SIGHUP))
            claude_stub.SIGNAL_TARGETS.finishing = True
            # Delivered before `os.kill` returns, so it lands with `finishing`
            # already set and is recorded as late rather than as unowned.
            os.kill(os.getpid(), signal.SIGTERM)
            return 3

        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), mock.patch.object(
            claude_stub.tempfile, "mkdtemp", recording_mkdtemp(created, root)
        ), mock.patch.object(
            claude_stub, "run_claude", recorded_then_signalled_while_finishing
        ):
            status = claude_stub.main(["--text", "x", "--", "-p", "hi"])

        self.assertEqual(3, status)
        self.assertEqual(
            [int(signal.SIGHUP), int(signal.SIGTERM)], self.targets.late_signums
        )
        self.assertIn(
            f"signals {int(signal.SIGHUP)}, {int(signal.SIGTERM)} arrived while "
            "exiting; nothing left to stop",
            stderr.getvalue(),
        )
        self.assertFalse(Path(created[0]).exists(), "the temp sandbox leaked")

    def test_two_ownerless_signals_back_to_back_are_both_reported(self):
        # Nothing masks the gap between two `raise_if_stopped` checkpoints, so
        # two truly-unmasked stop signals can land in it before either is
        # popped — the single-slot `unowned_signum` this replaced would have
        # let the second overwrite the first. Both are fired here from
        # `write_config`'s ignored-context window, before the stub server (or
        # anything else) exists to own either one: the first is popped by the
        # very next `raise_if_stopped` and becomes the exit status; the second
        # is left in `unowned_signums` for `main`'s cleanup to promote into
        # `late_signums`, and must reach the summary rather than vanish.
        root = Path(tempfile.mkdtemp(prefix="claudestub-test-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        created: list[str] = []
        first, second = int(signal.SIGTERM), int(signal.SIGHUP)
        real_write_config = claude_stub.write_config

        def fire_both(*args, **kwargs):
            result = real_write_config(*args, **kwargs)
            signal_from_a_context_that_ignores_exceptions(first)
            signal_from_a_context_that_ignores_exceptions(second)
            return result

        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), mock.patch.object(
            claude_stub, "SIGNAL_TARGETS", claude_stub.SignalTargets()
        ), mock.patch.object(
            claude_stub.tempfile, "mkdtemp", recording_mkdtemp(created, root)
        ), mock.patch.object(claude_stub, "write_config", fire_both):
            status = claude_stub.main(["--text", "x", "--", "-p", "hi"])

        self.assertEqual(128 + first, status)
        written = stderr.getvalue()
        self.assertIn(f"stopped by signal {first}", written)
        self.assertIn(
            f"signal {second} arrived while exiting; nothing left to stop",
            written,
            "the second ownerless signal was lost",
        )
        self.assertFalse(Path(created[0]).exists(), "the temp sandbox leaked")


class TerminalSigintTests(unittest.TestCase):
    """The position test that decides whether a SIGINT is forwarded.

    True means the wrapper is the terminal's foreground process group, so the
    tty delivered the SIGINT to the child as well and the wrapper must not send
    a second. It is a test of position and not of provenance — a Python handler
    gets no siginfo, so nothing here can tell a keypress from a `kill -INT`.
    """

    def test_a_tty_the_wrapper_is_not_the_foreground_group_of_is_not_shared(self):
        # A fresh pty is nobody's controlling terminal, so this process cannot
        # be its foreground group: no tty delivered this SIGINT to the child.
        master, slave = pty.openpty()
        self.addCleanup(os.close, master)
        self.addCleanup(os.close, slave)
        self.assertTrue(os.isatty(slave))
        self.assertFalse(claude_stub.sigint_reached_child_already(slave))

    def test_a_non_tty_stdin_means_no_terminal_delivered_it(self):
        read_fd, write_fd = os.pipe()
        self.addCleanup(os.close, read_fd)
        self.addCleanup(os.close, write_fd)
        self.assertFalse(claude_stub.sigint_reached_child_already(read_fd))

    def test_owning_the_terminals_foreground_group_means_the_child_got_it_too(self):
        with mock.patch.object(claude_stub.os, "isatty", return_value=True), \
             mock.patch.object(claude_stub.os, "tcgetpgrp", return_value=4242), \
             mock.patch.object(claude_stub.os, "getpgrp", return_value=4242):
            self.assertTrue(claude_stub.sigint_reached_child_already(0))


class QueuedSpawnSignalTests(SignalTargetsFixture):
    """A signal queued across the spawn, delivered once the child has a name.

    The handler cannot forward to a child that does not exist yet, so a stop
    signal landing inside `Popen` is parked in `pending_signum` and handed over
    by `run_claude`. That hand-off is unconditional — it skips the
    foreground-group check `deliver` applies to a live child, because the check
    answers whether the terminal delivered this signal to the child and for a
    queued signal it cannot: a signal from before the fork never reached a
    child that did not exist, and one from after it reaches a child too young
    to have installed a handler, which the terminal's own copy has already
    killed under the default disposition.

    What these exercise is the hand-off, not the race that fills the queue: a
    stand-in `Popen` parks `pending_signum` the way the handler would, because
    landing a real signal between a real fork and its `child = ...` assignment
    is a window microseconds wide and cannot be hit on demand. The real-signal
    races are covered by the subprocess tests below, which signal a live
    wrapper before `claude` is spawned.
    """

    def _run_with_queued(self, signum: int, foreground: bool) -> list[int]:
        class WaitableChild(FakeChild):
            def wait(self):
                return 0

        child = WaitableChild()

        def popen(*args, **kwargs):
            # What the handler does when it fires between the fork and the
            # `child = ...` assignment: nothing to forward to, so it queues.
            claude_stub.SIGNAL_TARGETS.pending_signum = signum
            return child

        with mock.patch.object(
            claude_stub.subprocess, "Popen", popen
        ), mock.patch.object(
            claude_stub,
            "sigint_reached_child_already",
            return_value=foreground,
        ):
            self.assertEqual(0, claude_stub.run_claude("claude", [], {}))
        return child.sent

    def test_a_queued_sigint_is_forwarded_even_from_the_foreground_group(self):
        # The discriminating case. The check is patched True — the answer a
        # real wrapper gets, since it runs after the child exists and shares
        # the group — and the queued SIGINT must be forwarded anyway: it landed
        # before the fork, so the terminal never delivered it to a child that
        # did not yet exist, and dropping it loses the user's Ctrl-C entirely.
        self.assertEqual(
            [int(signal.SIGINT)], self._run_with_queued(signal.SIGINT, True)
        )

    def test_a_queued_sigint_is_forwarded_from_outside_the_foreground_group(self):
        self.assertEqual(
            [int(signal.SIGINT)], self._run_with_queued(signal.SIGINT, False)
        )

    def test_a_queued_sigterm_is_delivered_whatever_the_terminal_did(self):
        for shared in (True, False):
            with self.subTest(shared=shared):
                self.assertEqual(
                    [int(signal.SIGTERM)],
                    self._run_with_queued(signal.SIGTERM, shared),
                )


class EarlyInterruptTests(SignalTargetsFixture):
    def test_a_ctrl_c_before_claude_runs_exits_130_and_removes_the_sandbox(self):
        # `main`'s KeyboardInterrupt belt, raised by a stand-in `run_claude`
        # rather than by a real SIGINT: this is the disposition that can still
        # fire either side of the handler's reign, and raising it directly is
        # the only way to land it there on demand. That a real SIGINT before
        # `claude` starts also exits 130 and strands nothing is the subprocess
        # test `test_a_sigint_before_claude_starts_is_handled_like_a_sigterm`.
        root = Path(tempfile.mkdtemp(prefix="claudestub-test-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        created: list[str] = []

        def interrupted(binary, claude_args, env):
            raise KeyboardInterrupt

        with mock.patch.object(
            claude_stub.tempfile, "mkdtemp", recording_mkdtemp(created, root)
        ):
            with mock.patch.object(claude_stub, "run_claude", interrupted):
                status = claude_stub.main(["--text", "x", "--", "-p", "hi"])

        self.assertEqual(130, status)
        self.assertEqual(1, len(created), "the wrapper did not create a temp sandbox")
        self.assertFalse(Path(created[0]).exists(), "the temp sandbox leaked")


class WrapperProcessTests(unittest.TestCase):
    """The wrapper as a process: signal handling and the cleanup scope.

    These run the wrapper by subprocess against a shell script standing in for
    `claude`, so they need no CLI and cost no tokens. Every wait is bounded and
    the wrapper gets its own process group, so a hang is killed rather than
    left behind.
    """

    DEADLINE = 30.0

    def _root(self) -> Path:
        root = Path(tempfile.mkdtemp(prefix="claudestub-test-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        return root

    @staticmethod
    def _fake_claude(path: Path, body: str) -> Path:
        path.write_text(f"#!/bin/sh\n{body}", encoding="utf-8")
        path.chmod(0o755)
        return path

    def _spawn_wrapper(
        self,
        root: Path,
        binary: Path,
        *extra: str,
        env: dict[str, str] | None = None,
    ) -> subprocess.Popen:
        cwd = root / "project"
        cwd.mkdir(exist_ok=True)
        devnull = open(os.devnull, "rb")
        self.addCleanup(devnull.close)
        # A new process group so a hung run is killed whole, never orphaned.
        wrapper = subprocess.Popen(
            [
                sys.executable,
                str(SCRIPT),
                "--text",
                "stubbed",
                "--claude-binary",
                str(binary),
                *extra,
                "--",
                "-p",
                "hi",
            ],
            cwd=cwd,
            env=env,
            stdin=devnull,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        self.addCleanup(self._kill_group, wrapper)
        return wrapper

    @staticmethod
    def _kill_group(wrapper: subprocess.Popen) -> None:
        """Kill the whole group, whether or not the wrapper is still alive.

        `start_new_session` made the wrapper its own group leader, so its pid
        is the group id and stays usable while any member survives — which is
        exactly the case that matters: a wrapper that died without forwarding
        leaves the stub `claude` behind in that group.
        """
        try:
            os.killpg(wrapper.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        if wrapper.poll() is None:
            wrapper.communicate()

    def _wait_for(self, predicate, description: str):
        deadline = time.monotonic() + self.DEADLINE
        while time.monotonic() < deadline:
            result = predicate()
            if result:
                return result
            time.sleep(0.05)
        self.fail(f"timed out after {self.DEADLINE}s waiting for {description}")

    def test_a_sigterm_to_the_wrapper_reaches_claude_and_still_cleans_up(self):
        # Without signal forwarding the interpreter dies where it stands: the
        # sandbox survives and `claude` is left running with nobody waiting.
        root = self._root()
        report = root / "child.txt"
        binary = self._fake_claude(
            root / "fake-claude.sh",
            f'printf \'%s\\n%s\\n\' "$$" "$HOME" > {shlex.quote(str(report))}\n'
            # `exec` keeps the pid just written, and the sleep outlasts the
            # deadline so "the child is gone" cannot pass by expiry.
            "exec sleep 600\n",
        )
        wrapper = self._spawn_wrapper(root, binary)

        def spawned():
            if wrapper.poll() is not None:
                self.fail("the wrapper exited before the stub claude reported in")
            lines = report.read_text(encoding="utf-8").splitlines() if report.exists() else []
            return lines if len(lines) == 2 else None

        child_pid, sandbox = self._wait_for(spawned, "the stub claude to report its pid")
        child_pid = int(child_pid)
        sandbox = Path(sandbox)

        wrapper.send_signal(signal.SIGTERM)
        try:
            stdout, stderr = wrapper.communicate(timeout=self.DEADLINE)
        except subprocess.TimeoutExpired:
            # An unforwarded SIGTERM kills the wrapper but leaves the child
            # holding its pipes open, so this is the shape that failure takes.
            self.fail(f"the wrapper did not finish {self.DEADLINE}s after SIGTERM")

        def child_gone():
            try:
                os.kill(child_pid, 0)
            except ProcessLookupError:
                return True
            return False

        self._wait_for(child_gone, f"the stub claude (pid {child_pid}) to exit")
        self.assertFalse(sandbox.exists(), f"the temp sandbox {sandbox} leaked")
        # A signal death is negative from Popen.wait; callers get 128 + signal.
        self.assertEqual(128 + int(signal.SIGTERM), wrapper.returncode, stderr)
        self.assertIn("request(s) served", stderr, stdout)

    def test_a_corrupted_reused_sandbox_config_fails_without_running_claude(self):
        # An explicit --sandbox is always kept, so this is about the failure
        # being reported and bounded rather than about cleanup.
        root = self._root()
        sandbox = root / "sandbox"
        (sandbox / "config").mkdir(parents=True)
        (sandbox / "config" / ".claude.json").write_text("{not json", encoding="utf-8")
        marker = root / "ran.txt"
        binary = self._fake_claude(
            root / "fake-claude.sh", f"touch {shlex.quote(str(marker))}\n"
        )
        wrapper = self._spawn_wrapper(root, binary, "--sandbox", str(sandbox))

        _, stderr = wrapper.communicate(timeout=self.DEADLINE)

        self.assertNotEqual(0, wrapper.returncode)
        self.assertIn("JSONDecodeError", stderr)
        self.assertFalse(marker.exists(), "claude ran despite the unreadable config")

    @staticmethod
    def _exit_status(returncode: int) -> int:
        """Popen reports a signal death as -N; a shell would report 128 + N.

        Both spellings are legitimate answers here: dying under the default
        disposition before the handlers exist and returning 128 + N from a
        handled signal are the same outcome to anyone reading `$?`.
        """
        return returncode if returncode >= 0 else 128 - returncode

    @staticmethod
    def _pid_gone(pid: int) -> bool:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        return False

    def _stop_signal_leaves_nothing_behind(self, sig: int, *, at_sandbox: bool) -> None:
        """Signal one wrapper run and assert the three invariants hold.

        `at_sandbox` waits for the temp sandbox to appear first, which puts the
        signal inside the window between the first resource existing and
        `claude` being spawned — the window the handlers used to leave open.
        Otherwise the signal goes immediately, landing before any resource
        exists at all. Whichever window it hits, the wrapper must report the
        signal, strand no sandbox, and leave no `claude` behind.
        """
        root = self._root()
        tmpdir = root / "tmp"
        tmpdir.mkdir()
        child_report = root / "child.txt"
        binary = self._fake_claude(
            root / "fake-claude.sh",
            f'printf \'%s\\n\' "$$" > {shlex.quote(str(child_report))}\n'
            # `exec` keeps the pid just written, and the sleep outlasts the
            # deadline so "the child is gone" cannot pass by expiry.
            "exec sleep 600\n",
        )
        wrapper = self._spawn_wrapper(
            root, binary, env={**os.environ, "TMPDIR": str(tmpdir)}
        )
        if at_sandbox:
            # Polled tightly on purpose: the window this aims at is only a few
            # milliseconds wide, so `_wait_for`'s 50 ms step would step over it.
            deadline = time.monotonic() + self.DEADLINE
            while time.monotonic() < deadline and not list(tmpdir.glob("claude-stub-*")):
                if wrapper.poll() is not None:
                    self.fail("the wrapper exited before creating a sandbox")
                time.sleep(0.001)

        wrapper.send_signal(sig)
        try:
            _, stderr = wrapper.communicate(timeout=self.DEADLINE)
        except subprocess.TimeoutExpired:
            self.fail(f"the wrapper did not finish {self.DEADLINE}s after signal {sig}")

        self.assertEqual([], list(tmpdir.glob("claude-stub-*")), f"a sandbox leaked\n{stderr}")
        if child_report.exists():
            child_pid = int(child_report.read_text(encoding="utf-8").split()[0])
            self._wait_for(
                lambda: self._pid_gone(child_pid),
                f"the stub claude (pid {child_pid}) to exit",
            )
        self.assertEqual(
            128 + int(sig), self._exit_status(wrapper.returncode), stderr
        )

    def test_a_sigterm_before_claude_starts_strands_neither_sandbox_nor_child(self):
        # The handlers have to be installed before the first resource exists.
        # Installed inside `run_claude` instead, a signal arriving while the
        # sandbox is built, the config written, or the stub server bound takes
        # the interpreter's default disposition: the wrapper dies where it
        # stands and the sandbox is stranded. Five runs are signalled the
        # instant the sandbox appears — inside that window — and one before
        # any resource exists at all.
        for attempt in range(5):
            with self.subTest(attempt=attempt):
                self._stop_signal_leaves_nothing_behind(signal.SIGTERM, at_sandbox=True)
        self._stop_signal_leaves_nothing_behind(signal.SIGTERM, at_sandbox=False)

    def test_a_sighup_before_claude_starts_is_handled_like_a_sigterm(self):
        self._stop_signal_leaves_nothing_behind(signal.SIGHUP, at_sandbox=True)

    def test_a_sigint_before_claude_starts_is_handled_like_a_sigterm(self):
        # SIGINT is a stop signal like the other two rather than being left to
        # Python's default KeyboardInterrupt, so it has to hold the same two
        # windows: the instant the sandbox appears, and before any resource
        # exists at all.
        #
        # `send_signal` here is `os.kill(wrapper.pid, SIGINT)`, not a Ctrl-C
        # typed at a terminal: `_spawn_wrapper` launches the wrapper with
        # `start_new_session=True`, so it has no controlling tty,
        # `sigint_reached_child_already` answers False, and the signal is
        # forwarded like any other. The foreground-group case — where the tty
        # delivered the Ctrl-C to the child too and the wrapper must not
        # forward a second — is covered by the unit tests instead.
        for attempt in range(5):
            with self.subTest(attempt=attempt):
                self._stop_signal_leaves_nothing_behind(signal.SIGINT, at_sandbox=True)
        self._stop_signal_leaves_nothing_behind(signal.SIGINT, at_sandbox=False)

    def test_a_sigint_while_claude_runs_reaches_it_and_still_cleans_up(self):
        # The window `wait()` occupies for the whole of a real session. Left to
        # KeyboardInterrupt the exception unwinds out of `run_claude` with the
        # child neither signalled nor waited for, and `main` removes the
        # sandbox under a `claude` that is still running.
        root = self._root()
        tmpdir = root / "tmp"
        tmpdir.mkdir()
        child_report = root / "child.txt"
        binary = self._fake_claude(
            root / "fake-claude.sh",
            f'printf \'%s\\n\' "$$" > {shlex.quote(str(child_report))}\n'
            # `exec` keeps the pid just written, and the sleep outlasts the
            # deadline so "the child is gone" cannot pass by expiry.
            "exec sleep 600\n",
        )
        wrapper = self._spawn_wrapper(
            root, binary, env={**os.environ, "TMPDIR": str(tmpdir)}
        )

        def reported():
            if wrapper.poll() is not None:
                self.fail("the wrapper exited before the stub claude reported in")
            text = child_report.read_text(encoding="utf-8").strip() if child_report.exists() else ""
            return int(text) if text else None

        child_pid = self._wait_for(reported, "the stub claude to report its pid")

        wrapper.send_signal(signal.SIGINT)
        try:
            _, stderr = wrapper.communicate(timeout=self.DEADLINE)
        except subprocess.TimeoutExpired:
            self.fail(f"the wrapper did not finish {self.DEADLINE}s after SIGINT")

        self._wait_for(
            lambda: self._pid_gone(child_pid),
            f"the stub claude (pid {child_pid}) to exit",
        )
        self.assertEqual(
            [], list(tmpdir.glob("claude-stub-*")), f"a sandbox leaked\n{stderr}"
        )
        self.assertEqual(130, self._exit_status(wrapper.returncode), stderr)
        self.assertIn("request(s) served", stderr)

    def _print_env_stops_on(self, sig: int) -> None:
        """Signal a `--print-env` server and assert it stopped cleanly.

        Every stop signal takes the same route here: the handler sets the
        serving event, `serve_until_signalled` returns normally, and the caller
        gets the closing summary and an exit status of 0 rather than a signal
        death with the temp sandbox left on disk.
        """
        root = self._root()
        tmpdir = root / "tmp"
        tmpdir.mkdir()
        cwd = root / "project"
        cwd.mkdir()
        out, err = root / "out.txt", root / "err.txt"
        with open(out, "w") as stdout, open(err, "w") as stderr, open(os.devnull, "rb") as devnull:
            wrapper = subprocess.Popen(
                [sys.executable, str(SCRIPT), "--print-env", "--text", "hi"],
                cwd=cwd,
                env={**os.environ, "TMPDIR": str(tmpdir)},
                stdin=devnull,
                stdout=stdout,
                stderr=stderr,
                start_new_session=True,
            )
        self.addCleanup(self._kill_group, wrapper)
        # Gated on the stderr `serving` line, not on the exports: the exports
        # are printed and flushed *before* `serve_until_signalled` publishes
        # the serving event, so a signal sent on the strength of stdout can
        # land in that gap, find no target, and unwind as `Terminated` with
        # status 130 instead of stopping the server. The `serving` line is
        # written after the event is published, so it is a true readiness
        # signal; `report` flushes, so it reaches this file as it is written.
        self._wait_for(
            lambda: "serving; Ctrl-C" in err.read_text(encoding="utf-8"),
            "the serving line on stderr",
        )
        self.assertIn("ANTHROPIC_BASE_URL", out.read_text(encoding="utf-8"))

        wrapper.send_signal(sig)
        try:
            wrapper.communicate(timeout=self.DEADLINE)
        except subprocess.TimeoutExpired:
            self.fail(f"the wrapper kept serving {self.DEADLINE}s after signal {sig}")

        stderr_text = err.read_text(encoding="utf-8")
        self.assertEqual(0, wrapper.returncode, stderr_text)
        self.assertIn("request(s) served", stderr_text)
        self.assertEqual([], list(tmpdir.glob("claude-stub-*")), "a sandbox leaked")

    def test_print_env_stops_on_sighup_and_still_reports_the_summary(self):
        # `serve_until_signalled` used to take SIGINT and SIGTERM only, so a
        # SIGHUP — the signal a closing terminal sends — killed the server
        # outright: no summary, and the temp sandbox left on disk.
        self._print_env_stops_on(signal.SIGHUP)

    def test_print_env_stops_on_sigint_and_still_reports_the_summary(self):
        # Ctrl-C is the documented way to stop a `--print-env` server, and it
        # now arrives at the handler rather than as a KeyboardInterrupt out of
        # `Event.wait()`. The summary has to survive the change of route.
        self._print_env_stops_on(signal.SIGINT)


class SandboxCleanupTests(SignalTargetsFixture):
    """Setup that fails after the sandbox exists, and what the latch does then.

    `SignalTargetsFixture` is not optional here: `main`'s cleanup latches
    `finishing` on the module global, so without the swap these runs would
    silence every later in-process test that expects a signal to be acted on.
    """

    def _failed_setup(self, root: Path) -> list[str]:
        """Run `main` with `write_config` raising; return the sandboxes made."""
        created: list[str] = []
        with mock.patch.object(
            claude_stub.tempfile, "mkdtemp", recording_mkdtemp(created, root)
        ):
            with mock.patch.object(
                claude_stub, "write_config", side_effect=RuntimeError("boom")
            ):
                with self.assertRaises(RuntimeError):
                    claude_stub.main(["--text", "x", "--", "-p", "hi"])
        return created

    def test_a_failure_after_the_temp_sandbox_exists_still_removes_it(self):
        # The auto-created sandbox is only reclaimable by the wrapper's own
        # `finally`, so setup that can fail has to sit inside it.
        root = Path(tempfile.mkdtemp(prefix="claudestub-test-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)

        created = self._failed_setup(root)

        self.assertEqual(1, len(created), "the wrapper did not create a temp sandbox")
        self.assertFalse(Path(created[0]).exists(), "the temp sandbox leaked")

    def test_a_failure_during_setup_still_arms_the_finishing_latch(self):
        # `write_config` failing means neither `run_claude` nor
        # `serve_until_signalled` ran, so the latch those two arm themselves
        # was never touched. Unarmed, a stop signal landing in the wrapper's
        # `shutil.rmtree` would find no target at all and raise `Terminated`
        # out of a half-walked sandbox — so `main`'s own cleanup has to arm it
        # for every path into that block, this one included.
        root = Path(tempfile.mkdtemp(prefix="claudestub-test-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)

        created = self._failed_setup(root)

        self.assertEqual(1, len(created), "the wrapper did not create a temp sandbox")
        self.assertFalse(Path(created[0]).exists(), "the temp sandbox leaked")
        self.assertTrue(
            self.targets.finishing,
            "a run that failed before spawning claude left the latch unarmed",
        )


@unittest.skipUnless(shutil.which("claude"), "no claude binary on PATH")
class LiveSmokeTests(unittest.TestCase):
    """One end-to-end run of the real CLI against the stub. Costs no tokens."""

    def test_a_headless_run_answers_from_the_stub_and_reports_one_request(self):
        root = Path(tempfile.mkdtemp(prefix="claudestub-smoke-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        cwd = root / "project"
        cwd.mkdir()
        # An explicit sandbox under the temp dir this test already reclaims:
        # on a timeout the wrapper is killed outright and its own `finally`
        # never runs, so the cleanup above has to be what removes the sandbox.
        sandbox = root / "sandbox"
        with open("/dev/null", "rb") as devnull:
            # A new process group, so a timeout kills claude too rather than
            # orphaning it when only the wrapper is signalled.
            child = subprocess.Popen(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--text",
                    "smoke",
                    "--sandbox",
                    str(sandbox),
                    "--",
                    "-p",
                    "hi",
                ],
                cwd=cwd,
                stdin=devnull,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                start_new_session=True,
            )
            try:
                stdout, stderr = child.communicate(timeout=180)
            except subprocess.TimeoutExpired:
                os.killpg(os.getpgid(child.pid), signal.SIGKILL)
                stdout, stderr = child.communicate()
                self.fail(f"the wrapper did not finish in 180s\n{stderr}")
        self.assertEqual(0, child.returncode, stderr)
        self.assertIn("smoke", stdout)
        self.assertIn("1 request(s) served", stderr)


if __name__ == "__main__":
    unittest.main()
