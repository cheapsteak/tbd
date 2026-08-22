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


# A stub `swift` that holds the build slot until it is signalled.
#
# `exec`, AND THE WHOLE POINT OF THIS CONSTANT. `swift-safe` execs the tool, so
# the process the fixture signals is this shell — and a plain `sleep 30` on the
# last line makes the sleep a CHILD of it, which no signal to the shell reaches.
# The shell died, the sleep was reparented, and two of them outlived the run on
# a CI runner, which reaped them itself and said so. `exec` collapses the two
# into one process, so the pid the fixture recorded at spawn IS the long-lived
# one and killing it leaves nothing behind.
HOLDING_SWIFT = "#!/bin/sh\nprintf 'ready\\n'\nexec sleep 30\n"


def _descendants_of(pid: int) -> list[int]:
    """Every live process below `pid`, from `ps` — BSD and GNU alike.

    Both accept `ps -eo pid=,ppid=`; neither `--ppid` (GNU) nor `-o ppid= -p`
    (which answers about one pid, not its children) is portable enough here.
    """
    listing = subprocess.run(
        ["ps", "-eo", "pid=,ppid="], capture_output=True, text=True, check=False
    ).stdout
    children: dict[int, list[int]] = {}
    for line in listing.splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[0].isdigit() and fields[1].isdigit():
            children.setdefault(int(fields[1]), []).append(int(fields[0]))
    found: list[int] = []
    pending = [pid]
    while pending:
        for child in children.get(pending.pop(), ()):
            found.append(child)
            pending.append(child)
    return found


@contextlib.contextmanager
def _lock_holder(env: dict[str, str], cwd: str | None = None):
    """Run a real swift-safe that takes the lock and keeps it until exit.

    Yields once the stub `swift` has printed, which happens only after the
    lock was taken and the holder record written — so a waiter started inside
    the block genuinely contends with a genuinely identified holder.

    Teardown is unconditional and signals only the pid recorded at spawn.
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
        try:
            process.terminate()
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            # A holder that ignored SIGTERM still may not outlive its test.
            process.kill()
            process.wait(timeout=5)
        finally:
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

    def runner_env(self, **extra_env) -> dict[str, str]:
        """The wrapper's environment with every knob it reads cleared first.

        A developer who exported `TBD_SWIFT_JOBS` for their own machine — the
        wrapper invites exactly that — must not decide what these cases
        observe, or the default cases assert their job count instead of the
        shipped one.  Each case states the settings it depends on itself.
        """
        env = {
            name: value
            for name, value in os.environ.items()
            if not name.startswith("TBD_SWIFT_")
        }
        env.update(
            {
                "TBD_HOME": str(self.tbd_home),
                "TBD_SWIFT_BIN": str(self.fake_swift),
                **extra_env,
            }
        )
        return env

    def run_runner(self, *arguments, **extra_env):
        return subprocess.run(
            [str(RUNNER), *arguments],
            text=True,
            capture_output=True,
            env=self.runner_env(**extra_env),
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

    def test_a_job_count_at_the_configured_limit_is_preserved(self):
        result = self.run_runner("build", "-j", "8", TBD_SWIFT_JOBS="8")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "build -j 8")

    def test_an_exported_job_count_is_honored_at_face_value(self):
        """The lock already caps the machine at one build, so no ceiling."""
        result = self.run_runner("build", TBD_SWIFT_JOBS="8")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "build --jobs 8")

    def test_a_large_exported_job_count_is_honored_too(self):
        """A big machine's owner sets the bound; the wrapper does not argue."""
        result = self.run_runner("test", "--filter", "Foo", TBD_SWIFT_JOBS="34")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "test --filter Foo --jobs 34")

    def test_a_job_count_past_the_core_count_is_honored_but_reported(self):
        """A typo'd digit is honored — and said out loud, on stderr only.

        9999 is past any machine's cores, so what this asserts does not depend
        on the machine running it; the core number itself is left unasserted
        for the same reason.
        """
        result = self.run_runner("build", TBD_SWIFT_JOBS="9999")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "build --jobs 9999")
        self.assertIn("this build will use 9999 jobs", result.stderr)
        self.assertIn("past this machine's", result.stderr)
        self.assertIn("CPU cores", result.stderr)
        self.assertIn("without speedup", result.stderr)

    def test_a_job_count_within_the_core_count_is_not_reported(self):
        """Mutation guard: 1 is at or below every machine's core count."""
        result = self.run_runner("build", TBD_SWIFT_JOBS="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "build --jobs 1")
        self.assertNotIn("past this machine's", result.stderr)

    def test_a_command_line_lowering_the_count_silences_the_report(self):
        """The line speaks for the build that runs, not for the bound it read.

        `-j 2` is what SwiftPM is handed, so warning about the 9999 the
        command line just lowered would name a build nobody asked for.
        """
        result = self.run_runner("build", "-j", "2", TBD_SWIFT_JOBS="9999")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "build -j 2")
        self.assertNotIn("past this machine's", result.stderr)
        self.assertNotIn("9999", result.stderr)

    def test_a_command_line_count_past_the_core_count_is_still_reported(self):
        """Mutation guard: lowering the bound is not the same as being safe."""
        result = self.run_runner("build", "-j", "9998", TBD_SWIFT_JOBS="9999")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "build -j 9998")
        self.assertIn("this build will use 9998 jobs", result.stderr)

    def test_the_shipped_default_never_reports_on_any_machine(self):
        """Nobody exported anything, so there is nobody to warn — and no knob.

        This must hold on a one-core machine or container too, where the
        shipped default of 2 is itself past the core count: a line naming
        TBD_SWIFT_JOBS to someone who never set it is noise they cannot
        silence.  Asserted with no `TBD_SWIFT_JOBS` in the environment at all,
        which `runner_env` guarantees.
        """
        result = self.run_runner("build")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "build --jobs 2")
        self.assertNotIn("past this machine's", result.stderr)
        self.assertNotIn("TBD_SWIFT_JOBS", result.stderr)

    def test_zero_and_negative_exported_job_counts_are_rejected(self):
        for value in ("0", "-1"):
            with self.subTest(value=value):
                result = self.run_runner("build", TBD_SWIFT_JOBS=value)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("must be positive", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_excessive_job_count_is_rejected(self):
        """A command line may lower the machine owner's bound, never raise it."""
        result = self.run_runner("test", "-j12")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exceeds TBD_SWIFT_JOBS=2", result.stderr)
        self.assertIn("raise TBD_SWIFT_JOBS", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_a_raised_limit_admits_the_command_line_count_it_rejected(self):
        """Same command, TBD_SWIFT_JOBS raised: the bound is the only gate."""
        result = self.run_runner("test", "-j12", TBD_SWIFT_JOBS="12")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "test -j12")

    def test_fractional_default_job_count_is_rejected(self):
        result = self.run_runner("build", TBD_SWIFT_JOBS="2.5")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be a positive integer", result.stderr)

    def test_non_compiling_package_commands_do_not_enter_the_governor(self):
        result = self.run_runner("package", "resolve")
        self.assertEqual(result.returncode, 64)
        self.assertIn("usage:", result.stderr)

    def test_execed_swift_keeps_the_lock(self):
        self.fake_swift.write_text(HOLDING_SWIFT, encoding="utf-8")
        with _lock_holder(self.runner_env()):
            result = self.run_runner(
                "test", TBD_SWIFT_LOCK_TIMEOUT_SECONDS="0.05"
            )
            self.assertEqual(result.returncode, 75)
            self.assertIn("timed out", result.stderr)

    def test_the_lock_holder_fixture_strands_no_process(self):
        """Nothing this fixture starts may outlive its block.

        Two `sleep`s from it outlived a CI run and the runner reaped them and
        said so: the stub `swift` forked its sleeper, so the SIGTERM that ended
        the shell never reached the child, which was reparented and kept
        running.  Recording every descendant while the block is open and
        asserting each is gone once it closes states that invariant whatever
        shape the stub takes.  Only pids observed here are ever looked at, and
        none of them is signalled.
        """
        self.fake_swift.write_text(HOLDING_SWIFT, encoding="utf-8")
        with _lock_holder(self.runner_env()) as holder:
            started = [holder.pid]
            # A forked sleeper appears a moment after "ready", so poll for one
            # rather than racing it.  The whole window is spent only when the
            # stub is well-behaved and there is nothing to find.
            deadline = time.monotonic() + 0.5
            while time.monotonic() < deadline:
                descendants = _descendants_of(holder.pid)
                if descendants:
                    started.extend(descendants)
                    break
                time.sleep(0.02)
        for pid in started:
            self.assertFalse(
                swift_safe._process_is_alive(pid),
                f"pid {pid} outlived the lock-holder fixture",
            )

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
        self.fake_swift.write_text(HOLDING_SWIFT, encoding="utf-8")
        with _lock_holder(self.runner_env(), cwd=str(holder_directory)) as holder:
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

    def _contended(self, *arguments, **extra_env):
        """Run the wrapper with the shared slot already held by this process."""
        lock_path = self.tbd_home / "runtime" / "swift-build.lock"
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        with lock_path.open("a+", encoding="utf-8") as lock_file:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return self.run_runner(*arguments, **extra_env)

    def test_yielding_exits_with_its_own_code(self):
        """76 is distinct from 75 so a caller can route the run elsewhere."""
        result = self._contended(
            "test",
            TBD_SWIFT_QUEUE_YIELD_SECONDS="0.05",
            TBD_SWIFT_LOCK_TIMEOUT_SECONDS="30",
        )
        self.assertEqual(result.returncode, 76)
        self.assertIn("yield", result.stderr.lower())
        self.assertEqual(result.stdout, "")

    def test_a_build_ignores_the_queue_yield_knob(self):
        """ONLY `test` MAY YIELD, because only its caller understands 76.

        `scripts/restart.sh` never checks this wrapper's status, so a developer
        who exported this knob in a shell profile would get a build that stops
        after the bound and a bundle assembled around whatever stale binaries
        were already on disk — the documented "a stale daemon reverts the fleet"
        failure. A build queues as usual and says once that the knob is not for
        it, because a knob ignored in silence looks like a knob that is broken.
        """
        result = self._contended(
            "build",
            TBD_SWIFT_QUEUE_YIELD_SECONDS="0.05",
            TBD_SWIFT_LOCK_TIMEOUT_SECONDS="0.5",
        )
        self.assertNotEqual(result.returncode, 76, "a build yielded its place")
        self.assertEqual(result.returncode, 75)
        self.assertIn("timed out", result.stderr)
        self.assertIn("only `test`", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_a_bad_yield_value_does_not_fail_a_build(self):
        # The validation is gated with the behaviour: a typo in a knob this
        # subcommand ignores must not turn an unrelated rebuild into a hard exit.
        result = self.run_runner("build", TBD_SWIFT_QUEUE_YIELD_SECONDS="soon")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "build --jobs 2")
        self.assertIn("only `test`", result.stderr)

    def test_a_bad_yield_value_still_fails_a_test_run(self):
        # Where the knob IS honoured, an unreadable value is refused by name
        # rather than silently meaning "never yield".
        result = self.run_runner("test", TBD_SWIFT_QUEUE_YIELD_SECONDS="soon")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TBD_SWIFT_QUEUE_YIELD_SECONDS", result.stderr)
        self.assertEqual(result.stdout, "")


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
                    # This process's own live ancestry, as `main` would record
                    # it: nothing here goes away, so the wait runs to timeout
                    # and the reporting is what is under test.
                    requester=os.getppid(),
                    ancestors=(),
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
        # `_acquire` reads the escape hatch from the ambient environment, and
        # docs/reclaim-build.md invites a developer to export it. Every case
        # below states for itself whether the hatch is set.
        patcher = mock.patch.dict(os.environ)
        patcher.start()
        self.addCleanup(patcher.stop)
        os.environ.pop("TBD_SWIFT_ALLOW_ORPHAN", None)
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

    def wait(self, parents, *, ancestors=(), release_slot=False, timeout=125.0):
        """One wait over the `parents` getppid readings; the last one repeats.

        `ancestors` is the chain recorded at startup, given as real pids so
        the shipped `kill(pid, 0)` liveness check is the one under test.

        The requester passed is `parents[0]`, the first reading — the same
        value `main` would have captured at startup. The escape-hatch cases
        pass it too, rather than production's zero, so that they still red if
        `_acquire`'s own `TBD_SWIFT_ALLOW_ORPHAN` gate is removed.

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
                    requester=parents[0],
                    ancestors=tuple(ancestors),
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

    def test_a_dead_grandparent_ends_the_wait_though_the_parent_lives(self):
        """The requester is rarely the direct parent — `env` execs in between.

        The parent reading never moves here: only the recorded chain shows
        that the process this build was being run for has gone.
        """
        # A live stand-in for the direct parent, then the dead grandparent.
        outcome, elapsed, _ = self.wait(
            [self.INITIAL_PARENT], ancestors=(os.getpid(), _dead_pid(), 1)
        )
        self.assertIs(outcome, swift_safe.Abandoned)
        self.assertLess(elapsed, 1.0)

    def test_a_wait_whose_whole_chain_lives_runs_to_the_timeout(self):
        """Mutation guard: a living ancestry must never fire the check."""
        outcome, elapsed, _ = self.wait(
            [self.INITIAL_PARENT], ancestors=(os.getpid(), os.getppid(), 1)
        )
        self.assertIs(outcome, TimeoutError)
        self.assertGreaterEqual(elapsed, 125.0)

    def test_an_unavailable_chain_falls_back_to_the_direct_parent(self):
        """A walk that failed records nothing, and must still behave."""
        outcome, elapsed, _ = self.wait([self.INITIAL_PARENT, 1], ancestors=())
        self.assertIs(outcome, swift_safe.Abandoned)
        self.assertLess(elapsed, 1.0)

        outcome, elapsed, _ = self.wait([self.INITIAL_PARENT], ancestors=())
        self.assertIs(outcome, TimeoutError)
        self.assertGreaterEqual(elapsed, 125.0)

    def test_allow_orphan_keeps_waiting_though_a_recorded_ancestor_died(self):
        with mock.patch.dict(os.environ, {"TBD_SWIFT_ALLOW_ORPHAN": "1"}):
            outcome, elapsed, _ = self.wait(
                [self.INITIAL_PARENT], ancestors=(os.getpid(), _dead_pid(), 1)
            )
        self.assertIs(outcome, TimeoutError)
        self.assertGreaterEqual(elapsed, 125.0)


class QueueYieldTests(unittest.TestCase):
    """Yielding is a caller-requested giveup, distinct from abandonment."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.lock_path = Path(self.temp.name) / "swift-build.lock"
        self.holder = self.lock_path.open("a+", encoding="utf-8")
        fcntl.flock(self.holder.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.env = mock.patch.dict(os.environ, {}, clear=False)
        self.env.start()
        os.environ.pop("TBD_SWIFT_ALLOW_ORPHAN", None)

    def tearDown(self):
        self.env.stop()
        self.holder.close()
        self.temp.cleanup()

    def wait(self, yield_seconds, timeout=600.0):
        clock = FakeClock()
        start = clock.monotonic()
        with self.lock_path.open("a+", encoding="utf-8") as waiter:
            outcome = None
            try:
                swift_safe._acquire(
                    waiter, self.lock_path, timeout, 60.0,
                    requester=os.getppid(), ancestors=(),
                    yield_after_seconds=yield_seconds,
                    monotonic=clock.monotonic, sleep=clock.sleep,
                    report=lambda *_: None, getppid=lambda: os.getppid(),
                )
            except BaseException as error:      # noqa: BLE001 - asserting the type
                outcome = error
            self.assertIsNotNone(outcome, "the wait acquired the build slot")
        return type(outcome), clock.monotonic() - start

    def test_the_wait_yields_once_the_threshold_passes(self):
        outcome, elapsed = self.wait(60.0)
        self.assertIs(outcome, swift_safe.Yielded)
        self.assertGreaterEqual(elapsed, 60.0)
        self.assertLess(elapsed, 61.0)

    def test_an_unset_threshold_never_yields(self):
        outcome, _ = self.wait(None, timeout=120.0)
        self.assertIs(outcome, TimeoutError)

    def test_a_threshold_beyond_the_timeout_never_yields(self):
        outcome, _ = self.wait(500.0, timeout=120.0)
        self.assertIs(outcome, TimeoutError)


class AncestorChainTests(unittest.TestCase):
    """The startup walk that records who a build is being run for."""

    def test_the_real_walk_reaches_pid_one_from_this_process(self):
        chain = swift_safe._ancestor_pids()
        self.assertEqual(chain[0], os.getppid())
        self.assertEqual(chain[-1], 1)
        self.assertEqual(len(set(chain)), len(chain), "the walk repeated a pid")
        self.assertTrue(all(swift_safe._process_is_alive(pid) for pid in chain))

    def test_the_real_process_table_maps_this_process_to_its_parent(self):
        self.assertEqual(swift_safe._process_table().get(os.getpid()), os.getppid())

    def test_the_walk_follows_the_table_up_to_pid_one(self):
        chain = swift_safe._ancestor_pids(
            getppid=lambda: 10, process_table=lambda: {10: 20, 20: 30, 30: 1, 1: 0}
        )
        self.assertEqual(chain, (10, 20, 30, 1))

    def test_a_missing_table_entry_ends_the_walk_at_the_direct_parent(self):
        chain = swift_safe._ancestor_pids(getppid=lambda: 10, process_table=dict)
        self.assertEqual(chain, (10,))

    def test_a_cyclic_table_terminates_the_walk(self):
        chain = swift_safe._ancestor_pids(
            getppid=lambda: 10, process_table=lambda: {10: 20, 20: 10}
        )
        self.assertEqual(chain, (10, 20))

    def test_a_detached_process_records_only_pid_one(self):
        chain = swift_safe._ancestor_pids(getppid=lambda: 1, process_table=dict)
        self.assertEqual(chain, (1,))

    def test_an_unusable_parent_records_nothing(self):
        self.assertEqual(
            swift_safe._ancestor_pids(getppid=lambda: 0, process_table=dict), ()
        )

    def test_an_unavailable_ps_leaves_an_empty_table(self):
        """No table means no chain, which is the pre-walk behavior, not a crash."""
        for failure in (
            OSError("no ps here"),
            subprocess.CalledProcessError(1, "ps"),
            subprocess.TimeoutExpired("ps", 10),
        ):
            with self.subTest(failure=type(failure).__name__):
                with mock.patch.object(
                    swift_safe.subprocess, "run", side_effect=failure
                ):
                    self.assertEqual(swift_safe._process_table(), {})
                    self.assertEqual(
                        swift_safe._ancestor_pids(getppid=lambda: 10), (10,)
                    )

    def test_unparsable_process_table_rows_are_skipped(self):
        completed = subprocess.CompletedProcess(
            ["ps"], 0, stdout="  1     0\nnot a row\n7 x\n8\n 9 10 11\n", stderr=""
        )
        with mock.patch.object(swift_safe.subprocess, "run", return_value=completed):
            self.assertEqual(swift_safe._process_table(), {1: 0})


class OrphanedWrapperTests(unittest.TestCase):
    """End to end: kill a queued wrapper's requester, through the real script.

    A killer signals the process it knows about, so the wrapper it started is
    never told.  Each case runs real shells that fork a real `swift-safe`
    against a real contended lock, then SIGKILLs one of them — by a pid this
    test recorded at spawn, never by a pattern, which once matched and killed
    unrelated live sessions.
    """

    DEADLINE_SECONDS = 3.0

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.lock_path = root / "swift-build.lock"
        self.compiled_marker = root / "swift-ran"
        self.wrapper_stderr = root / "wrapper.stderr"
        self.wrapper_pid_file = root / "wrapper.pid"
        self.intermediate_pid_file = root / "intermediate.pid"
        self.fake_swift = root / "swift"
        # No case here expects this to run — each asserts the marker stays
        # absent — but if one ever regresses, `exec` keeps the long-lived
        # process the same pid this test recorded, so teardown can end it.
        self.fake_swift.write_text(
            textwrap.dedent(
                f"""\
                #!/bin/sh
                printf '%s\\n' "$*" > {shlex.quote(str(self.compiled_marker))}
                exec sleep 30
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
        # Only pids these tests recorded at spawn are ever signalled: a
        # pattern kill here once matched, and killed, unrelated live sessions.
        self.recorded_pids: list[int] = []
        self.wrapper_pid = 0

    def tearDown(self):
        # Unconditional: a failed assertion must not strand a queued wrapper.
        for pid in self.recorded_pids:
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

    def wrapper_env(self, **extra_env) -> dict[str, str]:
        """The wrapper's environment with every knob it reads cleared first.

        Same reason as `SwiftSafeTests.runner_env`, plus one specific to these
        cases: an exported `TBD_SWIFT_JOBS` that is empty or not an integer
        makes the wrapper exit during argument parsing, before it ever reaches
        the wait loop — so the orphan check under test would never run and the
        failure would read as a broken check rather than a stray variable. The
        escape hatch goes with the rest; the hatch case below sets it back
        explicitly, as does every setting this suite depends on.
        """
        env = {
            name: value
            for name, value in os.environ.items()
            if not name.startswith("TBD_SWIFT_")
        }
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
        return env

    def reported_pid(self, pid_file: Path, description: str) -> int:
        """The pid a shell wrote for the child it forked, once it appears."""

        def pid_reported() -> bool:
            try:
                return pid_file.read_text().strip().isdigit()
            except OSError:
                return False

        self.assertTrue(
            self.until(pid_reported), f"no pid was reported for {description}"
        )
        pid = int(pid_file.read_text().strip())
        self.recorded_pids.append(pid)
        return pid

    def parent_of(self, pid: int) -> int:
        """This pid's parent, straight from `ps`, to verify the process tree."""
        completed = subprocess.run(
            ["ps", "-o", "ppid=", "-p", str(pid)],
            capture_output=True,
            text=True,
            check=False,
        )
        return int(completed.stdout.strip() or -1)

    def await_queued_wrapper(self) -> None:
        # Only once it is queued has it captured the requester it will lose.
        self.assertTrue(
            self.until(lambda: "waiting for the shared build slot" in self.reported()),
            "the wrapper never reached the wait",
        )

    def wrapper_script(self) -> str:
        """Fork the wrapper, report its pid, and stay alive around it.

        `&` so the shell forks rather than exec-optimizing the wrapper into
        itself: killing the shell then leaves a live wrapper behind, which is
        the leak being reproduced.
        """
        return (
            f"{shlex.quote(str(RUNNER))} build "
            f"2> {shlex.quote(str(self.wrapper_stderr))} & "
            f"echo $! > {shlex.quote(str(self.wrapper_pid_file))}; wait"
        )

    def start_queued_wrapper(self, **extra_env) -> subprocess.Popen:
        shell = subprocess.Popen(
            ["/bin/sh", "-c", self.wrapper_script()], env=self.wrapper_env(**extra_env)
        )
        self.shells.append(shell)
        self.wrapper_pid = self.reported_pid(self.wrapper_pid_file, "the wrapper")
        self.await_queued_wrapper()
        return shell

    def start_queued_wrapper_under_a_grandparent(self) -> subprocess.Popen:
        """grandparent shell -> intermediate shell -> queued wrapper.

        The shape `scripts/test.sh` produces: the wrapper's direct parent is
        an intermediate that outlives whoever asked for the build.  Every
        level must genuinely fork — a shell exec-optimizes the last simple
        command of `-c`, which would collapse the tree and make the test
        vacuous — so each backgrounds its child with `&` and stays in `wait`.
        """
        outer = (
            f"/bin/sh -c {shlex.quote(self.wrapper_script())} & "
            f"echo $! > {shlex.quote(str(self.intermediate_pid_file))}; wait"
        )
        grandparent = subprocess.Popen(["/bin/sh", "-c", outer], env=self.wrapper_env())
        self.shells.append(grandparent)
        intermediate_pid = self.reported_pid(
            self.intermediate_pid_file, "the intermediate shell"
        )
        self.wrapper_pid = self.reported_pid(self.wrapper_pid_file, "the wrapper")
        self.await_queued_wrapper()
        # Prove the three levels are distinct processes before killing any.
        self.assertEqual(self.parent_of(self.wrapper_pid), intermediate_pid)
        self.assertEqual(self.parent_of(intermediate_pid), grandparent.pid)
        self.assertNotIn(grandparent.pid, (intermediate_pid, self.wrapper_pid))
        return grandparent

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

    def test_a_wrapper_whose_grandparent_is_killed_stops_competing(self):
        """The direct parent survives, so only the recorded chain can notice.

        `scripts/test.sh` reaches the wrapper through `env`, which execs: kill
        the agent's shell and test.sh stays alive, blocked in `wait`.
        """
        grandparent = self.start_queued_wrapper_under_a_grandparent()
        # Exactly one pid, recorded when this test spawned it.
        self.kill_the_requester(grandparent)
        self.assertTrue(
            self.until(lambda: not swift_safe._process_is_alive(self.wrapper_pid)),
            "the wrapper kept waiting because its direct parent was still alive",
        )
        self.assertFalse(
            self.compiled_marker.exists(), "the orphan started a build nobody reads"
        )
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
