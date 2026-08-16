"""Tests for scripts/swift-safe (stdlib only).

Mostly black-box, through the real script.  The wait-reporting tests import
the script as a module instead, so they can drive `_acquire` with a fake
clock: the shipped heartbeat is a minute apart and no test may spend one.
"""

from __future__ import annotations

import contextlib
import fcntl
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import shlex
import signal
import subprocess
import tempfile
import textwrap
import time
import unittest
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parent.parent
RUNNER = REPO_ROOT / "scripts" / "swift-safe"


def _load_runner_module():
    """Import scripts/swift-safe (extensionless) as `swift_safe`."""
    loader = importlib.machinery.SourceFileLoader("swift_safe", str(RUNNER))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None, f"no import spec for {RUNNER}"
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


@contextlib.contextmanager
def _lock_holder(env: dict[str, str], cwd: str | None = None):
    """Run a real swift-safe that takes the lock and keeps it until exit.

    Yields once the stub `swift` has printed, which happens only after the
    lock was taken and the holder record written — so a waiter started inside
    the block genuinely contends with a genuinely identified holder.
    """
    process = subprocess.Popen(
        [str(RUNNER), "build"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=cwd,
        env=env,
    )
    stdout, stderr = process.stdout, process.stderr
    assert stdout is not None and stderr is not None
    try:
        assert stdout.readline().strip() == "ready"
        yield process
    finally:
        process.terminate()
        process.wait(timeout=5)
        stdout.close()
        stderr.close()


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
        with _lock_holder(env):
            result = self.run_runner(
                "test", TBD_SWIFT_LOCK_TIMEOUT_SECONDS="0.05"
            )
            self.assertEqual(result.returncode, 75)
            self.assertIn("timed out", result.stderr)

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

    def test_a_corrupt_holder_record_does_not_crash_the_waiter(self):
        """An unusable pid must degrade to "unidentified", never a traceback."""
        lock_path = self.tbd_home / "runtime" / "swift-build.lock"
        lock_path.parent.mkdir(parents=True)
        with lock_path.open("a+", encoding="utf-8") as lock_file:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            # Well-formed and numeric, but far past the platform's pid_t.
            lock_file.write("pid=99999999999\ncwd=/somewhere/acme-worktree\n")
            lock_file.flush()
            result = self.run_runner("build", TBD_SWIFT_LOCK_TIMEOUT_SECONDS="0.05")
        self.assertEqual(result.returncode, 75)
        self.assertNotIn("Traceback", result.stderr)
        self.assertIn("is not running", result.stderr)
        self.assertNotIn("acme-worktree", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_non_finite_wait_settings_are_rejected(self):
        """nan/inf survive float() and would silently disable the wait's limits."""
        for variable in (
            "TBD_SWIFT_LOCK_TIMEOUT_SECONDS",
            "TBD_SWIFT_HEARTBEAT_SECONDS",
        ):
            for value in ("nan", "inf", "-inf", "NaN", "Infinity"):
                with self.subTest(variable=variable, value=value):
                    result = self.run_runner("build", **{variable: value})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(variable, result.stderr)
                    # Rejected before SwiftPM is exec'd, not after.
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
        with _lock_holder(env, cwd=str(holder_directory)) as holder:
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
        self.assertIn(f"names pid {stale}, which is not running", description)
        self.assertIn("unidentified", description)
        self.assertNotIn("acme-worktree", description)
        self.assertNotIn("swift test", description)

    def test_non_positive_pids_are_never_probed_or_reported(self):
        # `os.kill(0, 0)` would signal this process's whole group, and a
        # negative pid a whole other group: neither is a holder.
        for recorded in ("0", "-1"):
            with self.subTest(pid=recorded):
                self.record(f"pid={recorded}\ncwd=/somewhere/acme-worktree\n")
                self.assertEqual(
                    self.description(), "holder has not recorded its identity yet"
                )

    def test_a_pid_too_large_for_the_platform_is_not_alive(self):
        # `os.kill` raises OverflowError — not an OSError — past pid_t's range.
        self.record(f"pid={2**31}\ncwd=/somewhere/acme-worktree\n")
        description = self.description()
        self.assertIn(f"names pid {2**31}, which is not running", description)
        self.assertNotIn("acme-worktree", description)

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
        self.assertIn("is not running", first)
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


class AbandonedWaitTests(unittest.TestCase):
    """Drive `_acquire`'s requester check with a fake clock and a fake getppid.

    The flock underneath is really contended, as in `WaitReportingTests`, so a
    wait that fails to notice its requester runs on to the full timeout.
    """

    INITIAL_PARENT = 4242

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.lock_path = Path(self.temp.name) / "swift-build.lock"
        self.holder = self.lock_path.open("a+", encoding="utf-8")
        fcntl.flock(self.holder.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)

    def tearDown(self):
        self.holder.close()
        self.temp.cleanup()

    def slot_is_free(self) -> bool:
        """Whether nobody — the waiter included — holds the lock right now."""
        with self.lock_path.open("a+", encoding="utf-8") as probe:
            try:
                fcntl.flock(probe.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return False
            fcntl.flock(probe.fileno(), fcntl.LOCK_UN)
            return True

    def wait(self, parents, *, release_slot=False, timeout=125.0):
        """One wait over the `parents` getppid readings; the last one repeats.

        Returns the exception type that ended it, the virtual seconds it
        lasted, and whether the slot was left untaken.
        """
        clock = FakeClock()
        readings = list(parents)

        def getppid() -> int:
            value = readings.pop(0) if len(readings) > 1 else readings[0]
            if release_slot and value != parents[0]:
                # Free the slot at the moment the requester goes away, so a
                # wait that failed to stop would take it and return happily.
                fcntl.flock(self.holder.fileno(), fcntl.LOCK_UN)
            return value

        start = clock.monotonic()
        with self.lock_path.open("a+", encoding="utf-8") as waiter:
            outcome: BaseException | None = None
            try:
                swift_safe._acquire(
                    waiter,
                    self.lock_path,
                    timeout,
                    60.0,
                    monotonic=clock.monotonic,
                    sleep=clock.sleep,
                    report=lambda *_: None,
                    getppid=getppid,
                )
            except (swift_safe.Abandoned, TimeoutError) as error:
                outcome = error
            self.assertIsNotNone(outcome, "the wait acquired the build slot")
            # Probed while the waiter's descriptor is still open, so a slot it
            # had taken would still read as busy.
            free = self.slot_is_free()
        return type(outcome), clock.monotonic() - start, free

    def test_the_wait_ends_when_the_requester_goes_away(self):
        outcome, elapsed, _ = self.wait([self.INITIAL_PARENT, self.INITIAL_PARENT, 1])
        self.assertIs(outcome, swift_safe.Abandoned)
        # Promptly: within a poll or two, not at the far-off timeout.
        self.assertLess(elapsed, 1.0)

    def test_an_abandoned_wait_leaves_the_freed_slot_untaken(self):
        outcome, _, free = self.wait([self.INITIAL_PARENT, 1], release_slot=True)
        self.assertIs(outcome, swift_safe.Abandoned)
        self.assertTrue(free, "the abandoned wait took the slot on its way out")

    def test_a_wait_whose_requester_stays_runs_to_the_timeout(self):
        """Mutation guard: the check must not fire while somebody is waiting."""
        outcome, elapsed, _ = self.wait([self.INITIAL_PARENT])
        self.assertIs(outcome, TimeoutError)
        self.assertGreaterEqual(elapsed, 125.0)

    def test_a_wait_that_started_detached_is_never_abandoned(self):
        """Reparenting is the signal; being parented to pid 1 all along is not."""
        outcome, elapsed, _ = self.wait([1])
        self.assertIs(outcome, TimeoutError)
        self.assertGreaterEqual(elapsed, 125.0)

    def test_allow_orphan_keeps_a_reparented_wait_queued(self):
        with mock.patch.dict(os.environ, {"TBD_SWIFT_ALLOW_ORPHAN": "1"}):
            outcome, elapsed, _ = self.wait([self.INITIAL_PARENT, 1])
        self.assertIs(outcome, TimeoutError)
        self.assertGreaterEqual(elapsed, 125.0)


class OrphanedWrapperTests(unittest.TestCase):
    """End to end: kill a queued wrapper's requester, through the real script.

    A killer signals the process it knows about, so the wrapper it started is
    never told.  Each case runs a real intermediate shell that forks a real
    `swift-safe` against a real contended lock, then SIGKILLs that shell only.
    """

    DEADLINE_SECONDS = 3.0

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.lock_path = root / "swift-build.lock"
        self.compiled_marker = root / "swift-ran"
        self.wrapper_stderr = root / "wrapper.stderr"
        self.wrapper_pid_file = root / "wrapper.pid"
        self.fake_swift = root / "swift"
        self.fake_swift.write_text(
            textwrap.dedent(
                f"""\
                #!/bin/sh
                printf '%s\\n' "$*" > {shlex.quote(str(self.compiled_marker))}
                sleep 30
                """
            ),
            encoding="utf-8",
        )
        self.fake_swift.chmod(0o755)
        # This process keeps the slot for the whole test, so the wrapper below
        # genuinely queues instead of compiling straight away.
        self.holder = self.lock_path.open("a+", encoding="utf-8")
        fcntl.flock(self.holder.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.shells: list[subprocess.Popen] = []
        self.wrappers: list[int] = []
        self.wrapper_pid = 0

    def tearDown(self):
        # Unconditional: a failed assertion must not strand a queued wrapper.
        for pid in self.wrappers:
            with contextlib.suppress(OSError):
                os.kill(pid, signal.SIGKILL)
        for shell in self.shells:
            with contextlib.suppress(OSError):
                shell.kill()
            with contextlib.suppress(subprocess.TimeoutExpired):
                shell.wait(timeout=5)
        self.holder.close()
        self.temp.cleanup()

    def until(self, condition) -> bool:
        """Poll `condition` up to the deadline rather than sleeping blind."""
        deadline = time.monotonic() + self.DEADLINE_SECONDS
        while time.monotonic() < deadline:
            if condition():
                return True
            time.sleep(0.02)
        return condition()

    def start_queued_wrapper(self, **extra_env) -> subprocess.Popen:
        env = os.environ.copy()
        env.update(
            {
                "TBD_HOME": str(Path(self.temp.name) / "tbd"),
                "TBD_SWIFT_LOCK_PATH": str(self.lock_path),
                "TBD_SWIFT_BIN": str(self.fake_swift),
                "TBD_SWIFT_LOCK_TIMEOUT_SECONDS": "60",
                "TBD_SWIFT_HEARTBEAT_SECONDS": "0.05",
                **extra_env,
            }
        )
        # `&` so the shell forks the wrapper: killing the shell then leaves a
        # live wrapper behind, which is the leak being reproduced.
        script = (
            f"{shlex.quote(str(RUNNER))} build "
            f"2> {shlex.quote(str(self.wrapper_stderr))} & "
            f"echo $! > {shlex.quote(str(self.wrapper_pid_file))}; wait"
        )
        shell = subprocess.Popen(["/bin/sh", "-c", script], env=env)
        self.shells.append(shell)
        def pid_reported() -> bool:
            try:
                return self.wrapper_pid_file.read_text().strip().isdigit()
            except OSError:
                return False

        self.assertTrue(
            self.until(pid_reported),
            "the intermediate shell never reported the wrapper's pid",
        )
        self.wrapper_pid = int(self.wrapper_pid_file.read_text().strip())
        self.wrappers.append(self.wrapper_pid)
        # Only once it is queued has it captured the requester it will lose.
        self.assertTrue(
            self.until(lambda: "waiting for the shared build slot" in self.reported()),
            "the wrapper never reached the wait",
        )
        return shell

    def reported(self) -> str:
        """Everything the wrapper has said on stderr so far."""
        try:
            return self.wrapper_stderr.read_text(errors="replace")
        except OSError:
            return ""

    def kill_the_requester(self, shell: subprocess.Popen) -> None:
        shell.kill()
        shell.wait(timeout=5)

    def test_a_wrapper_whose_requester_is_killed_stops_competing(self):
        shell = self.start_queued_wrapper()
        self.kill_the_requester(shell)
        self.assertTrue(
            self.until(lambda: not swift_safe._process_is_alive(self.wrapper_pid)),
            "the orphaned wrapper kept waiting for the shared build slot",
        )
        self.assertFalse(
            self.compiled_marker.exists(), "the orphan started a build nobody reads"
        )
        # The slot record still names this test's holder, never the orphan.
        self.assertNotIn(f"pid={self.wrapper_pid}", self.lock_path.read_text())
        self.assertIn("exited while it was queued", self.reported())

    def test_allow_orphan_keeps_a_deliberately_detached_wrapper_waiting(self):
        shell = self.start_queued_wrapper(TBD_SWIFT_ALLOW_ORPHAN="1")
        self.kill_the_requester(shell)
        self.assertFalse(
            self.until(lambda: not swift_safe._process_is_alive(self.wrapper_pid)),
            "the escape hatch did not keep the detached wrapper waiting",
        )
        self.assertNotIn("exited while it was queued", self.reported())


if __name__ == "__main__":
    unittest.main()
