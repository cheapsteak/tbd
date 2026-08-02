"""Black-box tests for scripts/swift-safe (stdlib only)."""

from __future__ import annotations

import fcntl
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


REPO_ROOT = Path(__file__).resolve().parent.parent
RUNNER = REPO_ROOT / "scripts" / "swift-safe"


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


if __name__ == "__main__":
    unittest.main()
