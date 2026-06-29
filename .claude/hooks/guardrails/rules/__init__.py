"""Rules package.

Every module in this package may expose a module-level `RULES = [...]` list of
Rule instances; the registry auto-discovers them via pkgutil. To add a guardrail,
drop a new module here exposing `RULES` — no other file needs to change.
"""
