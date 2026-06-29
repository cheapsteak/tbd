# Guardrails — repo-scoped PreToolUse enforcement

A small, extensible framework that inspects every Claude Code tool call **before**
it runs and can BLOCK it. Unlike advisory `CLAUDE.md` text, a `PreToolUse` hook
holds even under `--dangerously-skip-permissions`, so it is the right enforcement
layer for "NEVER do X" rules.

This framework is committed to the repo so it propagates to every worktree via git.

## Why this exists

An autonomous agent once ran a CI-load simulation that backgrounded `yes`
processes and reaped them with `kill $(jobs -p)`. Job control is OFF in the
non-interactive tool shell, so `jobs -p` returned nothing, `kill` reaped nothing,
and 22 `yes` processes orphaned to launchd at ~850% CPU for a week. Advisory text
could not prevent it; a `PreToolUse` hook can. See `rules/background_jobs.py`.

## Architecture

```
.claude/settings.json            ONE PreToolUse entry (matcher "Bash|Edit|Write") → dispatch.py
.claude/hooks/guardrails/
  dispatch.py                    entrypoint: read stdin JSON, run rules, aggregate, fail-open
  lib/rule.py                    Rule base class + Decision value
  lib/registry.py                auto-discovers rules/*.py and collects their RULES
  rules/<name>.py                a rule module exposing RULES = [MyRule()]
  tests/                         unittest suite (stdlib only)
  decisions.log                  runtime log (gitignored)
```

The whole point: **adding a future rule never touches `settings.json`.** The single
hook entry calls `dispatch.py`, which discovers all rule modules at runtime.

Python 3, stdlib only (`json`, `re`, `os`, `importlib`, `pkgutil`, `unittest`,
`datetime`). No third-party dependencies.

## The Rule interface

`lib/rule.py`:

```python
@dataclass
class Decision:
    action: str          # "deny" | "allow"
    reason: str = ""
    @staticmethod
    def deny(reason): ...
    @staticmethod
    def allow(): ...

class Rule:
    id: str              # stable id, prefixed onto deny reasons, shown by --list
    description: str     # one-line human description
    tools: set[str]      # tool_names this rule applies to, e.g. {"Bash"}
    def check(self, tool_input: dict, ctx: dict) -> Decision | None: ...
```

`check` returns:
- `None` — no opinion (allow). **Prefer this** when unsure; err toward allow.
- `Decision.deny(reason)` — block the call. The `reason` is fed back to the model
  via `permissionDecisionReason`, so make it instructive and tell the model how to
  fix the command. Prefix the reason with `[<rule-id>] ` so aggregated denies stay
  attributable.

`ctx` carries `session_id`, `cwd`, `permission_mode`, and `tool_name`.

## How to add a new rule

1. Create `rules/<name>.py` exposing a module-level `RULES` list:

   ```python
   from ..lib.rule import Decision, Rule

   class MyRule(Rule):
       id = "my-rule"
       description = "what it blocks, in one line"
       tools = {"Bash"}
       def check(self, tool_input, ctx):
           command = tool_input.get("command", "") or ""
           if <bad shape>:
               return Decision.deny("[my-rule] Blocked: ... Fix: ...")
           return None

   RULES = [MyRule()]
   ```

2. Add a test under `tests/` pinning both deny and allow cases.
3. Run `python3 dispatch.py --self-test` — it must pass.

**Do NOT edit `settings.json`.** The registry auto-discovers the new module.

## Deny / allow contract (Claude Code hook protocol)

- Hook reads JSON on **stdin**:
  `{session_id, transcript_path, cwd, permission_mode, hook_event_name, tool_name, tool_input}`.
  For Bash, `tool_input.command` is the command string.
- **ALLOW**: `exit 0` with no stdout.
- **BLOCK**: print
  `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"…"}}`
  to stdout and `exit 0`. This blocks the call even under
  `--dangerously-skip-permissions`. (We do NOT use legacy exit-code-2.)
- Multiple hooks merge most-restrictive-wins.

When several rules deny the same call, `dispatch.py` emits a single deny whose
reason concatenates each denying rule's reason (each already prefixed with its id).

## Fail-open

Every code path is wrapped in `try/except`. On ANY internal error — malformed
stdin, a rule that raises, a discovery failure — `dispatch.py` logs to
`decisions.log` and exits 0 (allow). **A buggy guardrail must never block the
agent.** Each rule is also run in its own try/except so one raising rule cannot
suppress a sibling's deny.

## CLI

```
python3 dispatch.py --list        # active rule ids + descriptions + tools
python3 dispatch.py --self-test   # run the unittest suite; exit nonzero on failure
```

## Logging

Every deny and every internal error is appended to `decisions.log` with a
timestamp, the tool name, the rule id, and a short command snippet. The log is
runtime-only and gitignored.

## Migration path

This framework is the home for the repo's advisory "NEVER …" rules. As those
hardenable invariants are identified, add them as rules here so they hold under
bypass-permissions instead of relying on advisory `CLAUDE.md` text alone.
