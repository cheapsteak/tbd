"""Tests for scripts/claude-stub.py (stdlib only).

Mostly the pure parts: turn scripting, the env overlay, the `--print-env`
exports, the sandbox config, and the closing summary. A second group runs the
wrapper as a process against a shell script standing in for `claude`, which is
the only way to observe signal handling and sandbox cleanup. One smoke test
spawns the real `claude` against the stub end to end, and skips when no
`claude` is on PATH. The e2e suite under `.github/workflows/claude-review-v2/tests/e2e/`
exercises the same fake server, but it drives the review gate's own scenarios
and never runs this wrapper, so nothing there covers the code here.
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


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

    def test_print_env_stops_on_sighup_and_still_reports_the_summary(self):
        # `serve_until_signalled` used to take SIGINT and SIGTERM only, so a
        # SIGHUP — the signal a closing terminal sends — killed the server
        # outright: no summary, and the temp sandbox left on disk.
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
        self._wait_for(
            lambda: "ANTHROPIC_BASE_URL" in out.read_text(encoding="utf-8"),
            "the export lines on stdout",
        )

        wrapper.send_signal(signal.SIGHUP)
        try:
            wrapper.communicate(timeout=self.DEADLINE)
        except subprocess.TimeoutExpired:
            self.fail(f"the wrapper kept serving {self.DEADLINE}s after SIGHUP")

        stderr_text = err.read_text(encoding="utf-8")
        self.assertEqual(0, wrapper.returncode, stderr_text)
        self.assertIn("request(s) served", stderr_text)
        self.assertEqual([], list(tmpdir.glob("claude-stub-*")), "a sandbox leaked")


class SandboxCleanupTests(unittest.TestCase):
    def test_a_failure_after_the_temp_sandbox_exists_still_removes_it(self):
        # The auto-created sandbox is only reclaimable by the wrapper's own
        # `finally`, so setup that can fail has to sit inside it.
        root = Path(tempfile.mkdtemp(prefix="claudestub-test-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        created: list[str] = []
        real_mkdtemp = tempfile.mkdtemp

        def recording_mkdtemp(*args, **kwargs):
            kwargs["dir"] = str(root)
            path = real_mkdtemp(*args, **kwargs)
            created.append(path)
            return path

        with mock.patch.object(claude_stub.tempfile, "mkdtemp", recording_mkdtemp):
            with mock.patch.object(
                claude_stub, "write_config", side_effect=RuntimeError("boom")
            ):
                with self.assertRaises(RuntimeError):
                    claude_stub.main(["--text", "x", "--", "-p", "hi"])

        self.assertEqual(1, len(created), "the wrapper did not create a temp sandbox")
        self.assertFalse(Path(created[0]).exists(), "the temp sandbox leaked")


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
