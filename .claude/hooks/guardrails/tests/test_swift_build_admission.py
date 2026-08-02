"""Pin the shared Swift build-admission guardrail."""

import os
import sys
import unittest

_HOOKS_DIR = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _HOOKS_DIR not in sys.path:
    sys.path.insert(0, _HOOKS_DIR)

from guardrails.rules.swift_build_admission import SwiftBuildAdmissionRule  # noqa: E402


def _check(command):
    return SwiftBuildAdmissionRule().check({"command": command}, {})


class SwiftBuildAdmissionTests(unittest.TestCase):
    def test_denies_raw_compile_commands(self):
        commands = [
            "swift build",
            "swift test --filter TranscriptPresentation",
            "cd /tmp && /usr/bin/swift test -j 12",
            "xcrun swift run TBDApp",
            "swift package resolve",
        ]
        for command in commands:
            with self.subTest(command=command):
                decision = _check(command)
                self.assertIsNotNone(decision)
                self.assertEqual(decision.action, "deny")
                self.assertIn("scripts/swift-safe", decision.reason)

    def test_allows_governed_and_non_compile_commands(self):
        commands = [
            "scripts/swift-safe build",
            "./scripts/swift-safe test --filter TranscriptPresentation",
            "swift --version",
            'echo "swift build"',
            "rg 'swift test' docs",
            "git diff -- Tests/TBDAppTests",
        ]
        for command in commands:
            with self.subTest(command=command):
                self.assertIsNone(_check(command))

    def test_safe_and_raw_commands_in_one_chain_still_deny(self):
        decision = _check("scripts/swift-safe build && swift test")
        self.assertIsNotNone(decision)
        self.assertEqual(decision.action, "deny")

    def test_nested_shell_commands_cannot_bypass_admission(self):
        commands = [
            'bash -c "swift build"',
            "sh -c 'swift test -j 12'",
            "/bin/zsh -lc 'cd /tmp && /usr/bin/swift package resolve'",
            "env FOO=bar bash -ec 'swift run TBDApp'",
            "echo \"$(bash -c 'swift build')\"",
            'printf "%s\\n" "$(swift test)"',
            "echo `swift package resolve`",
        ]
        for command in commands:
            with self.subTest(command=command):
                decision = _check(command)
                self.assertIsNotNone(decision)
                self.assertEqual(decision.action, "deny")

    def test_nested_shell_may_call_the_governed_runner(self):
        commands = [
            'bash -c "scripts/swift-safe build"',
            "zsh -lc './scripts/swift-safe test --filter Foo'",
        ]
        for command in commands:
            with self.subTest(command=command):
                self.assertIsNone(_check(command))


if __name__ == "__main__":
    unittest.main()
