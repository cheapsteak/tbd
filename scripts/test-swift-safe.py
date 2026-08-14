"""Tests for scripts/swift-safe (stdlib only).

Mostly black-box, through the real script.  The wait-reporting tests import
the script as a module instead, so they can drive `_acquire` with a fake
clock: the shipped heartbeat is a minute apart and no test may spend one.
"""

from __future__ import annotations

import fcntl
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


REPO_ROOT = Path(__file__).resolve().parent.parent
RUNNER = REPO_ROOT / "scripts" / "swift-safe"


def _load_runner_module():
    """Import scripts/swift-safe (extensionless) as `swift_safe`."""
    loader = importlib.machinery.SourceFileLoader("swift_safe", str(RUNNER))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


swift_safe = _load_runner_module()


class FakeClock:
    """Virtual monotonic time that only advances when the code sleeps."""

    def __init__(self):
        self.now = 1_000.0

    def monotonic(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


def _dead_pid() -> int:
    """A pid that has certainly exited and been reaped."""
    finished = subprocess.Popen(["/bin/sh", "-c", "exit 0"])
    finished.wait(timeout=5)
    return finished.pid


class SwiftSafeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.tbd_home = root / "tbd"
        self.fake_swift = root / "swift"
        self.fake_swift.write_text(
            textwrap.dedent(
                """\
                #!/bin/sh
                printf '%s\\n' "$*"
                """
            ),
            encoding="utf-8",
        )
        self.fake_swift.chmod(0o755)

    def tearDown(self):
        self.temp.cleanup()

    def run_runner(self, *arguments, **extra_env):
        env = os.environ.copy()
        env.update(
            {
                "TBD_HOME": str(self.tbd_home),
                "TBD_SWIFT_BIN": str(self.fake_swift),
                **extra_env,
            }
        )
        return subprocess.run(
            [str(RUNNER), *arguments],
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )

    def test_compile_commands_default_to_two_jobs(self):
        result = self.run_runner("test", "--filter", "Foo")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "test --filter Foo --jobs 2")

    def test_run_puts_jobs_before_the_executable(self):
        result = self.run_runner("run", "TBDApp", "--jobs", "99")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "run --jobs 2 TBDApp --jobs 99")

    def test_run_honors_swiftpm_jobs_but_ignores_app_jobs(self):
        result = self.run_runner("run", "-c", "release", "-j", "1", "TBDApp", "-j12")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "run -c release -j 1 TBDApp -j12")

    def test_existing_safe_job_count_is_preserved(self):
        result = self.run_runner("build", "-j", "1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "build -j 1")

    def test_excessive_job_count_is_rejected(self):
        result = self.run_runner("test", "-j12")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exceeds TBD_SWIFT_JOBS=2", result.stderr)

    def test_fractional_default_job_count_is_rejected(self):
        result = self.run_runner("build", TBD_SWIFT_JOBS="2.5")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be a positive integer", result.stderr)

    def test_non_compiling_package_commands_do_not_enter_the_governor(self):
        result = self.run_runner("package", "resolve")
        self.assertEqual(result.returncode, 64)
        self.assertIn("usage:", result.stderr)

    def test_execed_swift_keeps_the_lock(self):
        self.fake_swift.write_text(
            "#!/bin/sh\nprintf 'ready\\n'\nsleep 30\n",
            encoding="utf-8",
        )
        env = os.environ.copy()
        env.update({"TBD_HOME": str(self.tbd_home), "TBD_SWIFT_BIN": str(self.fake_swift)})
        first = subprocess.Popen(
            [str(RUNNER), "build"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        )
        try:
            self.assertEqual(first.stdout.readline().strip(), "ready")
            result = self.run_runner(
                "test", TBD_SWIFT_LOCK_TIMEOUT_SECONDS="0.05"
            )
            self.assertEqual(result.returncode, 75)
            self.assertIn("timed out", result.stderr)
        finally:
            first.terminate()
            first.wait(timeout=5)
            first.stdout.close()
            first.stderr.close()

    def test_contended_lock_times_out_without_spawning_swift(self):
        lock_path = self.tbd_home / "runtime" / "swift-build.lock"
        lock_path.parent.mkdir(parents=True)
        with lock_path.open("a+", encoding="utf-8") as lock_file:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_runner(
                "build", TBD_SWIFT_LOCK_TIMEOUT_SECONDS="0.05"
            )
        self.assertEqual(result.returncode, 75)
        self.assertIn("timed out", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_waiting_reports_the_holder_and_heartbeats_on_stderr(self):
        """End to end: a real waiter behind a real holder, compressed cadence."""
        holder_directory = Path(self.temp.name) / "acme-worktree"
        holder_directory.mkdir()
        self.fake_swift.write_text(
            "#!/bin/sh\nprintf 'ready\\n'\nsleep 30\n",
            encoding="utf-8",
        )
        env = os.environ.copy()
        env.update(
            {
                "TBD_HOME": str(self.tbd_home),
                "TBD_SWIFT_BIN": str(self.fake_swift),
            }
        )
        holder = subprocess.Popen(
            [str(RUNNER), "build"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=str(holder_directory),
            env=env,
        )
        try:
            self.assertEqual(holder.stdout.readline().strip(), "ready")
            result = self.run_runner(
                "test",
                TBD_SWIFT_LOCK_TIMEOUT_SECONDS="0.4",
                TBD_SWIFT_HEARTBEAT_SECONDS="0.05",
            )
            self.assertEqual(result.returncode, 75)
            self.assertIn("worktree acme-worktree", result.stderr)
            self.assertIn(f"pid {holder.pid}", result.stderr)
            self.assertIn("still waiting for the shared build slot after", result.stderr)
            # The worktree is named by its basename; the path is not disclosed.
            self.assertNotIn(str(holder_directory), result.stderr)
            # Nothing the waiter says may reach a caller parsing SwiftPM output.
            self.assertEqual(result.stdout, "")
        finally:
            holder.terminate()
            holder.wait(timeout=5)
            holder.stdout.close()
            holder.stderr.close()

    def test_run_warns_that_the_slot_covers_the_whole_program(self):
        result = self.run_runner("run", "TBDApp")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("until the program exits", result.stderr)
        self.assertEqual(result.stdout.strip(), "run --jobs 2 TBDApp")

    def test_build_does_not_warn_about_the_program_lifetime(self):
        result = self.run_runner("build")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("until the program exits", result.stderr)


class WaitReportingTests(unittest.TestCase):
    """Drive `_acquire` against a real contended flock with a fake clock."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.lock_path = Path(self.temp.name) / "swift-build.lock"
        # A second open file description in this same process genuinely
        # conflicts under flock, so the waiter below really does block.
        self.holder = self.lock_path.open("a+", encoding="utf-8")
        fcntl.flock(self.holder.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)

    def tearDown(self):
        self.holder.close()
        self.temp.cleanup()

    def record(self, text: str) -> None:
        self.holder.seek(0)
        self.holder.truncate()
        self.holder.write(text)
        self.holder.flush()

    def wait_messages(self, timeout=125.0, heartbeat=60.0, on_report=None):
        clock = FakeClock()
        messages: list[str] = []

        def report(message: str) -> None:
            messages.append(message)
            if on_report is not None:
                on_report(len(messages))

        with self.lock_path.open("a+", encoding="utf-8") as waiter:
            with self.assertRaises(TimeoutError):
                swift_safe._acquire(
                    waiter,
                    self.lock_path,
                    timeout,
                    heartbeat,
                    monotonic=clock.monotonic,
                    sleep=clock.sleep,
                    report=report,
                )
        return messages

    def test_first_line_names_the_holder_worktree_pid_and_command(self):
        self.record(
            f"pid={os.getpid()}\ncwd=/somewhere/acme-worktree\n"
            "command=swift build --jobs 2\n"
        )
        first = self.wait_messages()[0]
        self.assertIn("waiting for the shared build slot", first)
        self.assertIn("worktree acme-worktree", first)
        self.assertIn(f"pid {os.getpid()}", first)
        self.assertIn("running: swift build --jobs 2", first)
        self.assertNotIn("/somewhere/", first)

    def test_heartbeat_repeats_with_elapsed_time_on_the_configured_cadence(self):
        self.record(f"pid={os.getpid()}\ncwd=/somewhere/acme-worktree\n")
        messages = self.wait_messages(timeout=125.0, heartbeat=60.0)
        heartbeats = [m for m in messages if "still waiting" in m]
        self.assertEqual(len(messages), 3)
        self.assertEqual(len(heartbeats), 2)
        self.assertIn("after 60s of 125s", heartbeats[0])
        self.assertIn("after 120s of 125s", heartbeats[1])
        self.assertTrue(all("worktree acme-worktree" in m for m in heartbeats))

    def test_a_faster_cadence_produces_more_heartbeats(self):
        self.record(f"pid={os.getpid()}\n")
        heartbeats = [
            message
            for message in self.wait_messages(timeout=125.0, heartbeat=30.0)
            if "still waiting" in message
        ]
        self.assertEqual(len(heartbeats), 4)
        self.assertIn("after 30s of 125s", heartbeats[0])
        self.assertIn("after 120s of 125s", heartbeats[3])

    def test_shipped_cadence_clears_a_stall_watchdog_with_margin(self):
        self.assertLessEqual(swift_safe.DEFAULT_HEARTBEAT_SECONDS * 5, 600)

    def description(self) -> str:
        """The holder clause on its own, free of the surrounding wait line."""
        return swift_safe._holder_description(self.lock_path)

    def test_empty_lock_file_invents_no_holder(self):
        self.assertEqual(
            self.description(), "holder has not recorded its identity yet"
        )

    def test_missing_lock_file_invents_no_holder(self):
        self.lock_path.unlink()
        self.assertEqual(
            self.description(), "holder has not recorded its identity yet"
        )

    def test_partially_written_pid_line_is_not_trusted(self):
        self.record(f"pid={os.getpid()}")  # no terminating newline yet
        description = self.description()
        self.assertEqual(description, "holder has not recorded its identity yet")
        self.assertNotIn(str(os.getpid()), description)

    def test_partially_written_cwd_line_is_not_trusted(self):
        self.record(f"pid={os.getpid()}\ncwd=/somewhere/acme-work")
        description = self.description()
        self.assertEqual(description, f"held by pid {os.getpid()}")

    def test_stale_holder_identity_is_reported_as_gone(self):
        stale = _dead_pid()
        self.record(f"pid={stale}\ncwd=/somewhere/acme-worktree\ncommand=swift test\n")
        description = self.description()
        self.assertIn(f"names pid {stale}, which is no longer running", description)
        self.assertIn("unidentified", description)
        self.assertNotIn("acme-worktree", description)
        self.assertNotIn("swift test", description)

    def test_garbage_lock_file_invents_no_holder(self):
        self.record("\x00\x00 not a lock record at all\npid=not-a-number\n")
        self.assertEqual(
            self.description(), "holder has not recorded its identity yet"
        )

    def test_a_stale_description_still_reaches_the_wait_line(self):
        stale = _dead_pid()
        self.record(f"pid={stale}\ncwd=/somewhere/acme-worktree\n")
        first = self.wait_messages()[0]
        self.assertIn("waiting for the shared build slot", first)
        self.assertIn("no longer running", first)
        self.assertNotIn("acme-worktree", first)

    def test_heartbeat_rereads_a_holder_that_identifies_itself_late(self):
        """The holder records its identity only after acquiring, so re-read."""

        def populate(message_count: int) -> None:
            if message_count == 1:
                self.record(f"pid={os.getpid()}\ncwd=/somewhere/acme-worktree\n")

        messages = self.wait_messages(on_report=populate)
        self.assertIn("holder has not recorded its identity yet", messages[0])
        self.assertIn("worktree acme-worktree", messages[1])

    def test_an_over_long_command_is_truncated(self):
        self.record(f"pid={os.getpid()}\ncommand=swift build {'x' * 400}\n")
        first = self.wait_messages()[0]
        self.assertIn("...", first)
        self.assertLess(len(first), 400)


if __name__ == "__main__":
    unittest.main()
