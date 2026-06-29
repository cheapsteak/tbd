"""Rule discovery and aggregation.

`load_rules()` auto-discovers every module in the sibling `rules/` package, imports
it, and collects each module's `RULES` list (a list of Rule instances). Adding a
new rule therefore never requires touching this file or settings.json — drop a
`rules/<name>.py` exposing `RULES = [MyRule()]`.

Dependency-free: stdlib `importlib` + `pkgutil` only.
"""

from __future__ import annotations

import importlib
import pkgutil
from pathlib import Path

# The rules package is a sibling of this lib package: .../guardrails/rules.
# Derive its dotted name from this file's path rather than `__package__` (which
# can be None when the module is loaded in unusual ways) so discovery is
# bulletproof — a registry that raised here would silently go inert via the
# dispatcher's fail-open path.
_GUARDRAILS_PKG = Path(__file__).resolve().parent.parent.name  # "guardrails"
_RULES_PACKAGE = f"{_GUARDRAILS_PKG}.rules"


def load_rules() -> list:
    """Import every rule module and return the flattened list of Rule instances.

    Modules that fail to import or lack a well-formed `RULES` list are skipped so
    one broken rule file can never take down the whole guardrail set. dispatch.py
    additionally fails open at the call level.
    """
    rules_pkg = importlib.import_module(_RULES_PACKAGE)

    collected: list = []
    for module_info in pkgutil.iter_modules(rules_pkg.__path__):
        if module_info.name.startswith("_"):
            continue
        try:
            module = importlib.import_module(f"{_RULES_PACKAGE}.{module_info.name}")
        except Exception:  # noqa: BLE001 — isolate a single broken rule module
            # A SyntaxError or missing import in one rule file must not take down
            # every other rule. Without this guard the exception propagates out of
            # load_rules(), and the dispatcher's outer fail-open catch then drops
            # ALL rules — not just the broken one. Skip only the broken module.
            continue
        module_rules = getattr(module, "RULES", None)
        if not isinstance(module_rules, (list, tuple)):
            continue
        collected.extend(module_rules)
    return list(collected)
