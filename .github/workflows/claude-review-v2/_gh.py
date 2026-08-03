"""The single subprocess boundary to the `gh` CLI for the claude-review-v2 scripts.

Everything in this package that needs GitHub data calls `run_gh` on this module.
Tests monkeypatch this module attribute (`_gh.run_gh = fake`) so nothing else in
the package ever spawns a subprocess for gh. Do not add other gh call sites.
"""

from __future__ import annotations

import subprocess


def run_gh(args: list[str]) -> str:
    """Run `gh <args>` and return stdout. Raises RuntimeError on non-zero exit."""
    result = subprocess.run(
        ["gh", *args],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"gh {' '.join(args[:2])}... failed with exit {result.returncode}: "
            f"{result.stderr.strip()}"
        )
    return result.stdout
