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


if __name__ == "__main__":
    unittest.main()
