"""Make the script directory importable.

The package directory (`.github/workflows/claude-review-v2/`) sits under
hyphenated path components, so it cannot be imported as a package; the scripts
are flat modules (`prepare`, `validate`, `_gh`) that import each other by bare
name. Insert the directory at the FRONT of sys.path so those bare imports
resolve here regardless of where pytest is invoked from.
"""

from __future__ import annotations

import sys
from pathlib import Path

_SCRIPTS_DIR = str(Path(__file__).resolve().parent.parent)
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)
