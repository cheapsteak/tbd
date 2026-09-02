"""Tests for scripts/claude-stub.py (stdlib only).

Mostly the pure parts: turn scripting, the env overlay, the `--print-env`
exports, the sandbox config, and the closing summary. One smoke test spawns the
real `claude` against the stub end to end, and skips when no `claude` is on
PATH. The e2e suite under `.github/workflows/claude-review-v2/tests/e2e/`
exercises the same fake server, but it drives the review gate's own scenarios
and never runs this wrapper, so nothing there covers the code here.
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


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


class SummaryTests(unittest.TestCase):
    def _server(self, **kwargs):
        from stub_server import StubServer, Turn

        server = StubServer([Turn(text="one")], **kwargs)
        self.addCleanup(server._httpd.server_close)
        return server

    def test_the_summary_counts_requests_and_names_the_loopback_url(self):
        server = self._server()
        server.capture.raw_bodies.extend([b"{}", b"{}"])
        server.capture.routes.extend([None, None])
        lines = claude_stub.summary_lines(server, "http://127.0.0.1:4242")
        self.assertIn("2 request(s) served at http://127.0.0.1:4242", lines)
        self.assertIn(
            "no model request left this machine — ANTHROPIC_BASE_URL was "
            "http://127.0.0.1:4242 (loopback)",
            lines,
        )

    def test_the_connectivity_preflight_is_not_reported_as_unexpected(self):
        server = self._server()
        server.capture.unexpected_paths.extend(["/api/hello", "/v1/messages/count_tokens"])
        lines = claude_stub.summary_lines(server, "http://127.0.0.1:4242")
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
        lines = claude_stub.summary_lines(server, "http://127.0.0.1:4242")
        self.assertIn(f"  route {claude_stub.TITLE_LABEL}: 1", lines)
        self.assertIn("  route ROLE-SECURITY: 1", lines)
        self.assertIn("  route (ordered turns): 1", lines)

    def test_a_run_without_routing_reports_no_route_breakdown(self):
        server = self._server()
        server.capture.raw_bodies.append(b"{}")
        server.capture.routes.append(None)
        lines = claude_stub.summary_lines(server, "http://127.0.0.1:4242")
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


@unittest.skipUnless(shutil.which("claude"), "no claude binary on PATH")
class LiveSmokeTests(unittest.TestCase):
    """One end-to-end run of the real CLI against the stub. Costs no tokens."""

    def test_a_headless_run_answers_from_the_stub_and_reports_one_request(self):
        cwd = Path(tempfile.mkdtemp(prefix="claudestub-smoke-"))
        self.addCleanup(shutil.rmtree, cwd, ignore_errors=True)
        with open("/dev/null", "rb") as devnull:
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--text", "smoke", "--", "-p", "hi"],
                cwd=cwd,
                stdin=devnull,
                capture_output=True,
                text=True,
                timeout=180,
            )
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("smoke", result.stdout)
        self.assertIn("1 request(s) served", result.stderr)


if __name__ == "__main__":
    unittest.main()
