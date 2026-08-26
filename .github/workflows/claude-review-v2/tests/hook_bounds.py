"""The Stop hook's numeric bounds, read out of the hook itself.

The hold is held together by arithmetic between numbers that live in four
different files: the hook's own hold cap, nudge cap, wall-clock deadline and
wait window; the command timeout in `hooks/settings.json`; and the harness
block cap in the workflow. Every relation between them is silent when it
breaks — a window raised past the command timeout means every hold is killed
mid-wait and emits no block, and the session ends at the first stop attempt
with CI green.

So the tests that assert those relations read the numbers here rather than
restating them. A restated copy is exactly the drift they exist to catch: the
test keeps comparing its own stale literal to itself and stays green while the
hook it guards no longer holds.

Not a test module — pytest does not collect it.
"""

from __future__ import annotations

import re
from pathlib import Path

# .../.github/workflows/claude-review-v2/tests/ -> .../.github/workflows/
_WORKFLOWS_DIR = Path(__file__).resolve().parents[2]
HOOK_PATH = _WORKFLOWS_DIR / "claude-review-v2" / "hooks" / "stop-hook.sh"
SETTINGS_PATH = _WORKFLOWS_DIR / "claude-review-v2" / "hooks" / "settings.json"

_HOOK_NUMBER_RES = {
    "max_holds": re.compile(r"^\s*max_holds=(\d+)\s*$", re.MULTILINE),
    "max_blocks": re.compile(r"^\s*max_blocks=(\d+)\s*$", re.MULTILINE),
    "deadline": re.compile(r"^\s*hold_deadline_seconds=(\d+)", re.MULTILINE),
    # Both spellings of the wait window: the parameter expansion's default and
    # the fallback the non-numeric guard assigns. They are two literals of one
    # number, so both are collected and hook_number() requires them to agree.
    "window": re.compile(
        r"(?:REVIEW_HOLD_SLEEP_SECONDS:-|hold_sleep_seconds=)(\d+)"
    ),
}


def hook_number(name: str) -> int:
    """One of the hold's bounds, read out of the hook itself."""
    matches = _HOOK_NUMBER_RES[name].findall(HOOK_PATH.read_text(encoding="utf-8"))
    assert matches, (
        f"{HOOK_PATH.name} no longer sets `{name}` where this test looks for "
        "it; retarget the pattern rather than deleting the check"
    )
    assert len(set(matches)) == 1, f"{name} is spelled more than one way: {matches}"
    return int(matches[0])
